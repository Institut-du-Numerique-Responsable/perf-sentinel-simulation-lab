#!/usr/bin/env bash
# hub-correlations-push: a daemon pushes the periods a correlated pair was
# active, as episodes, and the Hub keeps them after the daemon forgets them.
#
# perf-sentinel 0.30.0 cuts an episode each time a pair of findings starts
# following each other again and pushes it to PerfSentinelHub 0.6.0's
# POST /api/import/correlations when [daemon.hub_export] and
# [daemon.correlation] are both on. An episode closes once the pair has not
# co-occurred for its gap, min(window, 30 min), one minute here.
#
# Legs, one numbered step each, on an isolated daemon and Hub:
#
#   0. Pre-flight. Keys, images, emit_at.py, the isolated pair with a one-minute
#      correlation window and a Hub that polls once a day.
#   1. The pair fires: N+1 in corpush-order, then 1 s later N+1 in
#      corpush-payment, five rounds. The Hub holds one open episode.
#   2. A silence past the gap. The daemon closes the episode, the Hub has its end.
#   3. The pair fires again with an incident posted during it. While it runs,
#      active=true lists the second episode alone. The Hub then holds two
#      episodes of the pair, and the incident's window overlaps the second only.
#   4. Nothing was dropped on the way.
#
# The pair is synthetic, sent with tools/tracegen/emit_at.py as
# correlation-event-time sends it: the shop's fault endpoints only reach the
# shared daemon through the collector, never an isolated one.
#
# Re-runnable. Everything lives in the scenario's own namespace, which the trap
# deletes.

set -euo pipefail

SCENARIO="hub-correlations-push"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMIT="${LAB_ROOT}/tools/tracegen/emit_at.py"

NS="${OBS_NS:-observability}"
ISO_NS="${HUB_CORRELATIONS_PUSH_NS:-hub-correlations-push}"
ISO_HUB_PORT="${HUB_CORRELATIONS_PUSH_HUB_PORT:-18097}"
ISO_DAEMON_PORT="${HUB_CORRELATIONS_PUSH_DAEMON_PORT:-14352}"
SOURCE_ID="lab-corpush-daemon"
ENVIRONMENT="lab"
SOURCE_SERVICE="corpush-order"
TARGET_SERVICE="corpush-payment"
ALERT_NS="corpush"
# The incident freezes 20 s back, so its window opens well after the first
# episode ended: only the second can overlap it.
LOOKBACK_MS=20000
# The payment side follows the order side by 1 s in event time, inside the
# 1.5 s lag threshold, while the next round's order side comes 3 s after it,
# outside it, so the reverse pair never forms.
LAG_MS=1000
SEND_GAP_S=2
ROUNDS=5
ROUNDS_AGAIN=10
# Three rounds into the second burst the pair is open again on the Hub.
INCIDENT_AFTER_S=12
# One flush interval, a request, a commit.
PUSH_WAIT_S=20
# The one-minute gap, a tracker round and a push on top of it.
CLOSE_WAIT_S=180
TRACE_BASE=$((0x5000))
TRACE_NUM=0

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
BURST_PID=""
cleanup() {
  [ -n "${BURST_PID}" ] && kill "${BURST_PID}" 2>/dev/null || true
  for pid in ${PF_PIDS[@]+"${PF_PIDS[@]}"}; do
    kill "${pid}" 2>/dev/null || true
  done
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${ISO_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# One Alertmanager delivery. $1 = service, $2 = status, $3 = startsAt, $4 = endsAt.
alert_body() {
  python3 -c "
import json, sys
service, status, starts, ends = sys.argv[1:5]
print(json.dumps({'version': '4', 'alerts': [{
    'status': status,
    'labels': {'service': service, 'perf_sentinel_kind': 'oom_kill', 'namespace': '${ALERT_NS}'},
    'annotations': {'summary': 'correlation push ' + service},
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

# The Hub's episodes of this source for the query $1, into ${TMP_DIR}/body.
episodes() { hub_api GET "/api/correlations?source_id=${SOURCE_ID}&$1" >/dev/null; }

# One N+1 trace of service $1 on table $2, stamped at $3 (epoch ms), in its own batch.
emit() {
  TRACE_NUM=$((TRACE_NUM + 1))
  python3 "${EMIT}" --endpoint "http://127.0.0.1:${ISO_DAEMON_PORT}" --service "$1" --shape n_plus_one \
    --table "$2" --at-ms "$3" --trace-num "$((TRACE_BASE + TRACE_NUM))" \
    >> "${TMP_DIR}/send.log" 2>> "${TMP_DIR}/send.err" || echo "$1" >> "${TMP_DIR}/send.failed"
}

# $1 rounds of the pair: the order side now, the payment side LAG_MS later in
# event time, each send in its own batch.
burst() {
  local round t
  for round in $(seq 1 "$1"); do
    t="$(now_ms)"
    emit "${SOURCE_SERVICE}" orders "${t}"
    sleep "${SEND_GAP_S}"
    emit "${TARGET_SERVICE}" payments "$((t + LAG_MS))"
    sleep "${SEND_GAP_S}"
  done
}

no_send_failed() {
  [ ! -s "${TMP_DIR}/send.failed" ] \
    || die "$(wc -l < "${TMP_DIR}/send.failed") send(s) failed, see ${TMP_DIR}/send.err: the legs would grade an incomplete pair"
}

step "0. Pre-flight"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
python3 -c 'import opentelemetry.proto' 2>/dev/null \
  || die "emit_at.py needs opentelemetry-proto: pip install -r ${LAB_ROOT}/tools/tracegen/requirements.txt"

KEY_DIR="${HUB_CORRELATIONS_KEY_DIR:-${LAB_ROOT}}"
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
DAEMON_IMAGE="${HUB_CORRELATIONS_PUSH_DAEMON_IMAGE:-$(kubectl -n "${NS}" get deploy/perf-sentinel-daemon -o jsonpath='{.spec.template.spec.containers[0].image}')}"
HUB_IMAGE="${HUB_CORRELATIONS_PUSH_HUB_IMAGE:-$(kubectl -n "${NS}" get deploy/perf-sentinel-hub -o jsonpath='{.spec.template.spec.containers[0].image}')}"
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
    # One trace per batch: a short TTL closes each trace before the next send.
    trace_ttl_ms = 1000

    [daemon.ack]
    enabled = false

    [daemon.incidents]
    enabled = true
    lookback_ms = ${LOOKBACK_MS}

    # A one-minute window makes the episode gap one minute.
    [daemon.correlation]
    enabled = true
    window_minutes = 1
    lag_threshold_ms = 1500
    min_co_occurrences = 2
    min_confidence = 0.5

    [detection]
    n_plus_one_min_occurrences = 5

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
        "Id": "${SOURCE_ID}", "Name": "correlation push lab daemon", "Environment": "${ENVIRONMENT}",
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

# A Hub without the route, or a daemon without the push, would fail leg 1 for the wrong reason.
ROUTE_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${ISO_HUB_PORT}/api/import/correlations?source_id=${SOURCE_ID}")"
[ "${ROUTE_CODE}" = "401" ] \
  || die "the Hub answered HTTP ${ROUTE_CODE} on POST /api/import/correlations without a key, 401 expected. Its image ${HUB_IMAGE} predates the route"
curl -s "http://127.0.0.1:${ISO_DAEMON_PORT}/metrics" | grep -q '^perf_sentinel_hub_export_correlations_pending ' \
  || die "the daemon publishes no perf_sentinel_hub_export_correlations_pending. Its image ${DAEMON_IMAGE} predates the correlation push"
ok "isolated pair in ${ISO_NS}: daemon ${DAEMON_IMAGE}, Hub ${HUB_IMAGE}, one-minute window, poll once a day"

step "1. The pair fires and the Hub holds an open episode"
burst "${ROUNDS}"
no_send_failed
FIRST=""
for _ in $(seq 1 "${PUSH_WAIT_S}"); do
  episodes "service=${SOURCE_SERVICE}"
  FIRST="$(jqp "' '.join([d[0]['id'], d[0]['pair_key'], d[0]['source']['finding_type'] + '>' + d[0]['target']['service']]) if len(d) == 1 and d[0].get('ended_at_ms') is None else ''" < "${TMP_DIR}/body")"
  [ -n "${FIRST}" ] && break
  sleep 1
done
read -r FIRST_ID PAIR_KEY FIRST_PAIR <<< "${FIRST:-- - -}"
if [ -n "${FIRST}" ] && [ "${FIRST_PAIR}" = "n_plus_one_sql>${TARGET_SERVICE}" ]; then
  ok "one open episode ${FIRST_ID}: ${SOURCE_SERVICE} then ${TARGET_SERVICE}"
  record "an active pair reaches the Hub" PASS "episode ${FIRST_ID}, pair ${PAIR_KEY}"
else
  fail "no single open episode of ${SOURCE_SERVICE} then ${TARGET_SERVICE} on the Hub"
  record "an active pair reaches the Hub" FAIL "$(head -c 200 "${TMP_DIR}/body")"
  die "no episode to follow, the later legs would grade nothing"
fi

step "2. A silence past the gap closes it"
# Closed by the daemon: an end, and no ended_by, which only the Hub's stale rule sets.
STATE="missing"
for _ in $(seq 1 "${CLOSE_WAIT_S}"); do
  episodes "pair_key=${PAIR_KEY}"
  STATE="$(jqp "next((('stale' if r.get('ended_by') == 'stale' else 'closed' if r.get('ended_at_ms') is not None else 'open') for r in d if r['id'] == '${FIRST_ID}'), 'missing')" < "${TMP_DIR}/body")"
  [ "${STATE}" = "closed" ] && break
  sleep 1
done
if [ "${STATE}" = "closed" ]; then
  ok "the daemon closed ${FIRST_ID} and the Hub carries the end"
  record "the daemon closes the episode after the gap" PASS "ended_at_ms set, ended_by null"
else
  fail "${FIRST_ID} still reads '${STATE}' after ${CLOSE_WAIT_S} s"
  record "the daemon closes the episode after the gap" FAIL "state ${STATE}"
fi

step "3. The pair fires again, an incident posted during it"
burst "${ROUNDS_AGAIN}" &
BURST_PID="$!"
sleep "${INCIDENT_AFTER_S}"
CODE="$(daemon_api POST /api/incidents "$(alert_body "${SOURCE_SERVICE}" firing "$(minutes_ago 0)" "0001-01-01T00:00:00Z")" "${WRITE_KEY}")"
[ "${CODE}" = "200" ] || die "the daemon refused the alert (HTTP ${CODE}): $(head -c 200 "${TMP_DIR}/body")"
ACTIVE=""
for _ in $(seq 1 "${PUSH_WAIT_S}"); do
  episodes "active=true"
  ACTIVE="$(jqp "','.join(r['id'] for r in d)" < "${TMP_DIR}/body")"
  [ -n "${ACTIVE}" ] && [ "${ACTIVE}" != "${FIRST_ID}" ] && break
  sleep 1
done
SECOND_ID=""
if [ -n "${ACTIVE}" ] && [ "${ACTIVE}" = "${ACTIVE%%,*}" ] && [ "${ACTIVE}" != "${FIRST_ID}" ]; then
  SECOND_ID="${ACTIVE}"
  ok "while it runs, active=true lists ${SECOND_ID} alone"
  record "the second episode is the only active one" PASS "active=true: ${SECOND_ID}"
else
  fail "active=true lists '${ACTIVE}'"
  record "the second episode is the only active one" FAIL "active=true: '${ACTIVE}'"
fi
wait "${BURST_PID}" || true
BURST_PID=""
no_send_failed

episodes "pair_key=${PAIR_KEY}"
TWO="$(jqp "len(d) == 2 and d[0]['id'] == '${SECOND_ID}' and d[1]['id'] == '${FIRST_ID}' and d[1].get('ended_at_ms') is not None and d[0]['started_at_ms'] > d[1]['ended_at_ms']" < "${TMP_DIR}/body")"
if [ "${TWO}" = "True" ]; then
  ok "two episodes of the pair, the second started after the first ended"
  record "a pair active twice is two episodes" PASS "${FIRST_ID} then ${SECOND_ID}"
else
  fail "the pair's episodes are not the two expected: $(head -c 300 "${TMP_DIR}/body")"
  record "a pair active twice is two episodes" FAIL "$(jqp "len(d)" < "${TMP_DIR}/body") episode(s)"
fi

WINDOW=""
for _ in $(seq 1 "${PUSH_WAIT_S}"); do
  hub_api GET "/api/incidents?source_id=${SOURCE_ID}&service=${SOURCE_SERVICE}" >/dev/null
  WINDOW="$(jqp "'%d %d' % (d[0]['window_from_ms'], d[0]['ended_at_ms'] or d[0]['window_to_ms']) if len(d) == 1 else ''" < "${TMP_DIR}/body")"
  [ -n "${WINDOW}" ] && break
  sleep 1
done
[ -n "${WINDOW}" ] || die "the incident never reached the Hub, the overlap leg has no window"
read -r WIN_FROM WIN_TO <<< "${WINDOW}"
episodes "from=${WIN_FROM}&to=${WIN_TO}"
OVERLAP="$(jqp "','.join(r['id'] for r in d)" < "${TMP_DIR}/body")"
if [ -n "${SECOND_ID}" ] && [ "${OVERLAP}" = "${SECOND_ID}" ]; then
  ok "the incident's window [${WIN_FROM}, ${WIN_TO}] overlaps the second episode alone"
  record "the incident overlaps the second episode only" PASS "window ${WIN_FROM}-${WIN_TO}"
else
  fail "the incident's window overlaps '${OVERLAP}', ${SECOND_ID} expected"
  record "the incident overlaps the second episode only" FAIL "overlap '${OVERLAP}'"
fi

step "4. Nothing was dropped"
DROPPED=""; PENDING=""
for _ in $(seq 1 10); do
  curl -s "http://127.0.0.1:${ISO_DAEMON_PORT}/metrics" > "${TMP_DIR}/metrics"
  DROPPED="$(awk '/^perf_sentinel_hub_export_correlations_dropped_total /{print $2}' "${TMP_DIR}/metrics")"
  PENDING="$(awk '/^perf_sentinel_hub_export_correlations_pending /{print $2}' "${TMP_DIR}/metrics")"
  [ "${PENDING}" = "0" ] && break
  sleep 1
done
if [ "${DROPPED}" = "0" ] && [ "${PENDING}" = "0" ]; then
  ok "no episode dropped, none left pending"
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
  echo "Isolated pair in namespace \`${ISO_NS}\`, source \`${SOURCE_ID}\`, one-minute correlation window, Hub poll once a day."
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
