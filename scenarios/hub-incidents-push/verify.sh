#!/usr/bin/env bash
# hub-incidents-push: a daemon pushes its incidents to the Hub, so one its ring
# evicts before any poll still lands.
#
# perf-sentinel 0.29.0 pushes incidents beside findings when [daemon.hub_export]
# and [daemon.incidents] are both on, to PerfSentinelHub 0.5.0's
# POST /api/import/incidents. Before that the Hub only read incidents on its
# hourly poll, and an incident the ring evicted in between never reached it.
# scenarios/hub-incidents-mirror covers the poll path. This one covers the push,
# with the poll pushed out of the way.
#
# Legs, one numbered step each, on an isolated daemon and Hub:
#
#   0. Pre-flight. Keys, images, the isolated pair with a ring of two, a Hub
#      that polls once a day, and nothing in this script that asks it to read.
#   1. Five incidents through a ring that keeps two. The daemon ends up holding
#      two, and the Hub holds all five, every one of them pushed.
#   2. A resolved alert carries its end to the Hub, pushed as well.
#   3. Nothing was dropped on the way.
#
# Re-runnable. Everything lives in the scenario's own namespace, which the trap
# deletes.

set -euo pipefail

SCENARIO="hub-incidents-push"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

NS="${OBS_NS:-observability}"
ISO_NS="${HUB_INCIDENTS_PUSH_NS:-hub-incidents-push}"
ISO_HUB_PORT="${HUB_INCIDENTS_PUSH_HUB_PORT:-18095}"
ISO_DAEMON_PORT="${HUB_INCIDENTS_PUSH_DAEMON_PORT:-14349}"
SOURCE_ID="lab-push-daemon"
ENVIRONMENT="lab"
SERVICE_PREFIX="incpush-svc"
ALERT_NS="incpush"
LOOKBACK_MS=300000
# How long a push may take to land: one flush interval, a request, a commit.
PUSH_WAIT_S=20

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

declare -a PF_PIDS=()
cleanup() {
  for pid in ${PF_PIDS[@]+"${PF_PIDS[@]}"}; do
    kill "${pid}" 2>/dev/null || true
  done
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${ISO_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# One Alertmanager delivery. $1 = service, $2 = status, $3 = startsAt, $4 = endsAt.
alert_body() {
  python3 -c "
import json, sys
service, status, starts, ends = sys.argv[1:5]
print(json.dumps({'version': '4', 'alerts': [{
    'status': status,
    'labels': {'service': service, 'perf_sentinel_kind': 'oom_kill', 'namespace': '${ALERT_NS}'},
    'annotations': {'summary': 'push ' + service},
    'startsAt': starts,
    'endsAt': ends,
}]}))
" "$1" "$2" "$3" "$4"
}

# $1 = minutes ago, as RFC 3339 in UTC.
minutes_ago() {
  python3 -c "
import datetime, sys
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=int(sys.argv[1]))
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}

# $1 = method, $2 = path, $3 = body ("" for none), $4 = key ("" for none).
# Prints the HTTP code, leaves the body in ${TMP_DIR}/body.
daemon_api() {
  local args=(-s -o "${TMP_DIR}/body" -w '%{http_code}' -X "$1")
  [ -n "${3:-}" ] && args+=(-H "content-type: application/json" -d "$3")
  [ -n "${4:-}" ] && args+=(-H "X-API-Key: $4")
  curl "${args[@]}" "http://127.0.0.1:${ISO_DAEMON_PORT}$2"
}

hub_api() {
  curl -s -o "${TMP_DIR}/body" -w '%{http_code}' -X "$1" "http://127.0.0.1:${ISO_HUB_PORT}$2"
}

# The Hub's incidents of this scenario's services, as "<count>".
hub_count() {
  hub_api GET "/api/incidents?source_id=${SOURCE_ID}&limit=100" >/dev/null
  jqp "len([r for r in d if r['service'].startswith('${SERVICE_PREFIX}-')])" < "${TMP_DIR}/body"
}

step "0. Pre-flight"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"

KEY_DIR="${HUB_INCIDENTS_KEY_DIR:-${LAB_ROOT}}"
WRITE_KEY_FILE="${KEY_DIR}/.perf-sentinel-incidents.key"
READ_KEY_FILE="${KEY_DIR}/.perf-sentinel-read.key"
[ -f "${WRITE_KEY_FILE}" ] || die "no incidents write key at ${WRITE_KEY_FILE}. Run: make up"
[ -f "${READ_KEY_FILE}" ] || die "no read key at ${READ_KEY_FILE}. Run: make up"
WRITE_KEY="$(cat "${WRITE_KEY_FILE}")"
READ_KEY="$(cat "${READ_KEY_FILE}")"
# The import key is the scenario's own, never stored: it lives as long as the namespace.
IMPORT_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"

# The images under test are the ones the shared pair runs, seeded from the two
# branches with make seed-daemon-local and make seed-hub-local.
DAEMON_IMAGE="${HUB_INCIDENTS_PUSH_DAEMON_IMAGE:-$(kubectl -n "${NS}" get deploy/perf-sentinel-daemon -o jsonpath='{.spec.template.spec.containers[0].image}')}"
HUB_IMAGE="${HUB_INCIDENTS_PUSH_HUB_IMAGE:-$(kubectl -n "${NS}" get deploy/perf-sentinel-hub -o jsonpath='{.spec.template.spec.containers[0].image}')}"
[ -n "${DAEMON_IMAGE}" ] && [ -n "${HUB_IMAGE}" ] || die "no daemon or Hub image to run. Run: make seed-daemon-local and make seed-hub-local"

for _ in $(seq 1 60); do
  [ "$(kubectl get namespace "${ISO_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Terminating" ] || break
  sleep 2
done
kubectl create namespace "${ISO_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${ISO_NS}" create secret generic api-keys \
  --from-literal=incidents-api-key="${WRITE_KEY}" --from-literal=read-api-key="${READ_KEY}" \
  --from-literal=import-api-key="${IMPORT_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - >/dev/null <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata: {name: daemon-config, namespace: ${ISO_NS}}
data:
  config.toml: |
    [daemon]
    listen_address = "0.0.0.0"
    listen_port_http = 14318
    listen_port_grpc = 14317
    api_enabled = true
    environment = "staging"

    [daemon.ack]
    enabled = false

    # A ring of two: the third incident evicts the first.
    [daemon.incidents]
    enabled = true
    lookback_ms = ${LOOKBACK_MS}
    max_retained = 2

    [daemon.hub_export]
    enabled = true
    endpoint = "http://hub.${ISO_NS}.svc.cluster.local:8080/api/import/findings"
    source_id = "${SOURCE_ID}"
    api_key_file = "/etc/perf-sentinel-hub/import.key"
    flush_interval_secs = 1
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: daemon, namespace: ${ISO_NS}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: daemon}}
  template:
    metadata: {labels: {app: daemon}}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: perf-sentinel
          image: ${DAEMON_IMAGE}
          imagePullPolicy: Never
          args: [watch, --config, /etc/perf-sentinel/config.toml]
          ports: [{name: http, containerPort: 14318}]
          env:
            - name: PERF_SENTINEL_INCIDENTS_API_KEY
              valueFrom: {secretKeyRef: {name: api-keys, key: incidents-api-key}}
            - name: PERF_SENTINEL_READ_API_KEY
              valueFrom: {secretKeyRef: {name: api-keys, key: read-api-key}}
          volumeMounts:
            - {name: config, mountPath: /etc/perf-sentinel, readOnly: true}
            - {name: import-key, mountPath: /etc/perf-sentinel-hub, readOnly: true}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          readinessProbe:
            httpGet: {path: /health, port: http}
            periodSeconds: 2
      volumes:
        - name: config
          configMap: {name: daemon-config}
        - name: import-key
          secret:
            secretName: api-keys
            items: [{key: import-api-key, path: import.key}]
---
apiVersion: v1
kind: Service
metadata: {name: daemon, namespace: ${ISO_NS}}
spec:
  selector: {app: daemon}
  ports: [{name: http, port: 14318, targetPort: http}]
---
apiVersion: v1
kind: ConfigMap
metadata: {name: hub-config, namespace: ${ISO_NS}}
data:
  appsettings.Production.json: |
    {"Hub": {
      "DatabasePath": "/data/hub.db",
      "PollInterval": "1.00:00:00",
      "HttpTimeout": "00:00:05",
      "Retention": "180.00:00:00",
      "ResolutionGrace": "01:00:00",
      "MaxReadLimit": 10000,
      "Sources": [{
        "Id": "${SOURCE_ID}", "Name": "push lab daemon", "Environment": "${ENVIRONMENT}",
        "BaseUrl": "http://daemon.${ISO_NS}.svc.cluster.local:14318",
        "AuthHeaderName": "X-API-Key"
      }]
    }}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: hub, namespace: ${ISO_NS}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: hub}}
  template:
    metadata: {labels: {app: hub}}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1654
        runAsGroup: 1654
        fsGroup: 1654
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: hub
          image: ${HUB_IMAGE}
          imagePullPolicy: Never
          ports: [{name: http, containerPort: 8080}]
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: Production
            - name: Hub__Sources__0__AuthHeaderValue
              valueFrom: {secretKeyRef: {name: api-keys, key: read-api-key}}
            - name: Hub__Sources__0__ImportApiKey
              valueFrom: {secretKeyRef: {name: api-keys, key: import-api-key}}
          volumeMounts:
            - {name: config, mountPath: /app/appsettings.Production.json, subPath: appsettings.Production.json, readOnly: true}
            - {name: data, mountPath: /data}
            - {name: tmp, mountPath: /tmp}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          readinessProbe:
            httpGet: {path: /health/ready, port: http}
            periodSeconds: 2
      volumes:
        - name: config
          configMap: {name: hub-config}
        - name: data
          emptyDir: {}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata: {name: hub, namespace: ${ISO_NS}}
spec:
  selector: {app: hub}
  ports: [{name: http, port: 8080, targetPort: http}]
EOF
# The Hub first, so the daemon's first pushes find it answering.
kubectl -n "${ISO_NS}" rollout status deploy/hub --timeout=180s >/dev/null \
  || die "the isolated Hub did not become ready: $(kubectl -n "${ISO_NS}" logs deploy/hub --tail=20 2>&1)"
kubectl -n "${ISO_NS}" rollout status deploy/daemon --timeout=180s >/dev/null \
  || die "the isolated daemon did not become ready: $(kubectl -n "${ISO_NS}" logs deploy/daemon --tail=20 2>&1)"

iso_forward() {  # $1 = service, $2 = local port, $3 = remote port, $4 = probe path
  local i pid
  kubectl -n "${ISO_NS}" port-forward "svc/$1" "$2:$3" >"${TMP_DIR}/pf-$1.log" 2>&1 &
  pid="$!"
  PF_PIDS+=("${pid}")
  disown "${pid}" 2>/dev/null || true
  for i in $(seq 1 40); do
    curl -sf "http://127.0.0.1:$2$4" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
iso_forward hub "${ISO_HUB_PORT}" 8080 /health/ready || die "the isolated Hub never answered on ${ISO_HUB_PORT}"
iso_forward daemon "${ISO_DAEMON_PORT}" 14318 /health || die "the isolated daemon never answered on ${ISO_DAEMON_PORT}"

# A Hub without the route would make leg 1 fail for the wrong reason.
ROUTE_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${ISO_HUB_PORT}/api/import/incidents?source_id=${SOURCE_ID}")"
[ "${ROUTE_CODE}" = "401" ] \
  || die "the Hub answered HTTP ${ROUTE_CODE} on POST /api/import/incidents without a key, 401 expected. Its image ${HUB_IMAGE} predates the route"
ok "isolated pair in ${ISO_NS}: daemon ${DAEMON_IMAGE}, Hub ${HUB_IMAGE}, ring of 2, poll once a day"

step "1. Five incidents through a ring that keeps two"
LAST_STARTS=""
for i in 1 2 3 4 5; do
  LAST_STARTS="$(minutes_ago "$((6 - i))")"
  CODE="$(daemon_api POST /api/incidents "$(alert_body "${SERVICE_PREFIX}-${i}" firing "${LAST_STARTS}" "0001-01-01T00:00:00Z")" "${WRITE_KEY}")"
  [ "${CODE}" = "200" ] || die "the daemon refused alert ${i} (HTTP ${CODE}): $(head -c 200 "${TMP_DIR}/body")"
done
HUB=0
for _ in $(seq 1 "${PUSH_WAIT_S}"); do
  HUB="$(hub_count)"
  [ "${HUB}" = "5" ] && break
  sleep 1
done
daemon_api GET "/api/incidents?findings=false" "" "${READ_KEY}" >/dev/null
RING="$(jqp "len([r for r in d if r['service'].startswith('${SERVICE_PREFIX}-')])" < "${TMP_DIR}/body")"
if [ "${RING}" = "2" ] && [ "${HUB}" = "5" ]; then
  ok "the daemon holds 2, the Hub holds all 5 without a single poll"
  record "an evicted incident still reaches the Hub" PASS "ring ${RING}, Hub ${HUB}/5"
else
  fail "the daemon holds ${RING} (2 expected) and the Hub ${HUB} of 5"
  record "an evicted incident still reaches the Hub" FAIL "ring ${RING}, Hub ${HUB}/5"
fi

step "2. A resolved alert carries its end to the Hub"
ENDS="$(minutes_ago 0)"
CODE="$(daemon_api POST /api/incidents "$(alert_body "${SERVICE_PREFIX}-5" resolved "${LAST_STARTS}" "${ENDS}")" "${WRITE_KEY}")"
[ "${CODE}" = "200" ] || die "the daemon refused the resolve (HTTP ${CODE})"
ENDED="False"
for _ in $(seq 1 "${PUSH_WAIT_S}"); do
  hub_api GET "/api/incidents?source_id=${SOURCE_ID}&service=${SERVICE_PREFIX}-5" >/dev/null
  ENDED="$(jqp "len(d) == 1 and d[0].get('ended_at_ms') is not None" < "${TMP_DIR}/body")"
  [ "${ENDED}" = "True" ] && break
  sleep 1
done
if [ "${ENDED}" = "True" ]; then
  ok "the Hub carries the end"
  record "a resolve reaches the Hub" PASS "ended_at_ms set without a poll"
else
  fail "the Hub has no end for ${SERVICE_PREFIX}-5"
  record "a resolve reaches the Hub" FAIL "ended_at_ms missing"
fi

step "3. Nothing was dropped"
curl -s "http://127.0.0.1:${ISO_DAEMON_PORT}/metrics" > "${TMP_DIR}/metrics"
DROPPED="$(awk '/^perf_sentinel_hub_export_incidents_dropped_total /{print $2}' "${TMP_DIR}/metrics")"
PENDING="$(awk '/^perf_sentinel_hub_export_incidents_pending /{print $2}' "${TMP_DIR}/metrics")"
if [ "${DROPPED}" = "0" ] && [ "${PENDING}" = "0" ]; then
  ok "no incident dropped, none left pending"
  record "nothing dropped" PASS "dropped ${DROPPED}, pending ${PENDING}"
else
  fail "dropped '${DROPPED}', pending '${PENDING}'"
  record "nothing dropped" FAIL "dropped '${DROPPED}', pending '${PENDING}'"
fi

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Daemon: \`${DAEMON_IMAGE}\`"
  echo
  echo "Hub: \`${HUB_IMAGE}\`"
  echo
  echo "Isolated pair in namespace \`${ISO_NS}\`, source \`${SOURCE_ID}\`, ring of 2, Hub poll once a day, no refresh."
  echo
  echo "| Sub-test | Verdict | Note |"
  echo "| --- | --- | --- |"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
} > "${REPORT}"

step "Report written to ${REPORT}"
for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
