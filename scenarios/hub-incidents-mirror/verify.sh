#!/usr/bin/env bash
# hub-incidents-mirror: the daemon-to-Hub incident chain, over the shared pair
# and, for its last leg, an isolated one.
#
# perf-sentinel 0.20.0 freezes the findings of the window that preceded an
# alert. PerfSentinelHub 0.1.6 mirrors those records into SQLite and serves
# them back. Nothing in either repository joins the two: the Hub's own tests
# drive a fake daemon, the daemon's tests never see a Hub.
# scenarios/incident-window-capture proves the daemon half against a local
# binary, scenarios/hub-ingestion proves the findings half over the cluster.
# The incident half of the chain, which is the copy an operator opens after
# the pod that produced it is gone, had no coverage anywhere.
#
# Legs, one numbered step each:
#
#   A. Pre-flight. Both keys, both deployments, both forwards, and a daemon
#      that reports the incident store enabled and a read key set.
#   B. The capture. A finding seeded for one service, then one Alertmanager
#      envelope posted with the WRITE key, then the daemon's own record read
#      back with the READ key: service, window bounds, frozen findings and the
#      namespace label the alert carried.
#   C. The mirror. The Hub reads the fleet on demand rather than waiting out
#      its poll interval, lists the incident keyed per source and WITHOUT its
#      findings, then serves them whole on the single-incident route,
#      signature for signature. This is the assertion the scenario exists for:
#      the Hub holds a copy of the daemon's record, not a re-derivation of it.
#   D. The filters. service, namespace, kind and source_id each narrow, a free
#      string with no match is an empty page, and a value naming configuration
#      the Hub knows is closed answers 400.
#   E. Failure isolation. A refused read key marks the source's
#      incidents_state unauthorized and says nothing about its findings.
#   F. The archive replay. Since 0.24.0 the daemon reloads its ring from
#      [daemon.incidents] archive_path at startup, and the shared daemon keeps
#      that archive on the perf-sentinel-acks PVC, so a restart brings the
#      incident back with the signatures it froze.
#   G. Retention and the richest copy, on an isolated daemon and Hub in the
#      scenario's own namespace. That daemon has no archive_path, so its ring
#      dies with its pod, the Hub's copy does not, and a later poorer capture
#      of the same id never replaces it.
#
# Re-runnable. The incident id is content-derived, so a repost is the same
# incident, every mutation this script makes to the shared pair is undone in
# the trap, and the trap deletes the isolated namespace.

set -euo pipefail

SCENARIO="hub-incidents-mirror"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

NS="${OBS_NS:-observability}"
HUB_PORT="${HUB_LOCAL_PORT:-8080}"
DAEMON_PORT="${DAEMON_LOCAL_PORT:-14318}"

# Deterministic service names: tracegen builds "<prefix>-<nonce>-<index>", so a
# fixed nonce lets a re-run reuse the findings the previous one left in the
# ring instead of paying for another seed.
SERVICE="${HUB_INCIDENTS_SERVICE:-incmirror-probe-0000}"
# The second incident exists only so the filters in leg D have something to
# exclude. Its service never emits a span, which is fine: the join key decides
# which findings are frozen, and freezing none of them is a valid capture.
GHOST_SERVICE="incmirror-ghost-0000"
ALERT_NS="${HUB_INCIDENTS_NAMESPACE:-incident-lab}"
GHOST_NS="incident-lab-ghost"
SOURCE_ID="lab-daemon"
ENVIRONMENT="lab"
# [daemon.incidents] lookback_ms in manifests/perf-sentinel-daemon.yaml.
# /api/config publishes trace_ttl_ms but not this, so it is mirrored here and
# the window assertion below is what catches the two drifting apart.
LOOKBACK_MS=300000
# The Hub debounces a refresh of a source it read this recently, see
# ApiEndpoints.Incidents.RefreshDebounceMs. Two reads in a row have to straddle
# it or the second one silently serves the stored copy.
REFRESH_DEBOUNCE_S=11

# Leg G's isolated pair. The shared daemon replays its archive at startup, so
# only a daemon with no archive_path loses its ring on a restart.
ISO_NS="${HUB_INCIDENTS_ISO_NS:-hub-incidents-mirror}"
ISO_HUB_PORT="${HUB_INCIDENTS_ISO_HUB_PORT:-18094}"
ISO_DAEMON_PORT="${HUB_INCIDENTS_ISO_DAEMON_PORT:-14348}"
# Short, so the settle pass the leg waits out lands in seconds.
ISO_TTL_MS=5000

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

# The Hub's source entry, as manifests/perf-sentinel-hub.yaml declares it. Leg
# E replaces the value half with a literal and this puts the reference back,
# so the two patches together are a round trip on one env var of one
# Deployment. Nothing else in the cluster is touched: the shared Secret keeps
# the key both sides agree on, so no other scenario and no other workload can
# observe the swap.
HUB_KEY_PATCHED=0
HUB_ENV_WRONG='{"spec":{"template":{"spec":{"containers":[{"name":"perf-sentinel-hub","env":[{"name":"Hub__Sources__0__AuthHeaderValue","value":"not-the-read-key","valueFrom":null}]}]}}}}'
HUB_ENV_RESTORE='{"spec":{"template":{"spec":{"containers":[{"name":"perf-sentinel-hub","env":[{"name":"Hub__Sources__0__AuthHeaderValue","value":null,"valueFrom":{"secretKeyRef":{"name":"perf-sentinel-api-keys","key":"read-api-key"}}}]}]}}}}'

# The flag is cleared only once the patch has landed, so a restore that failed
# mid-leg is attempted again from the trap rather than left to rot.
restore_hub_key() {
  [ "${HUB_KEY_PATCHED}" = "1" ] || return 0
  if kubectl -n "${NS}" patch deploy/perf-sentinel-hub --type=strategic -p "${HUB_ENV_RESTORE}" >/dev/null; then
    HUB_KEY_PATCHED=0
  else
    color_red "    error: the Hub still holds the wrong read key. Restore it with:"
    color_red "    kubectl -n ${NS} patch deploy/perf-sentinel-hub --type=strategic -p '${HUB_ENV_RESTORE}'"
  fi
  kubectl -n "${NS}" rollout status deploy/perf-sentinel-hub --timeout=180s >/dev/null 2>&1 || true
}

declare -a PF_PIDS=()
cleanup() {
  restore_hub_key
  kubectl -n "${NS}" delete job "${SCENARIO}-seed" --ignore-not-found >/dev/null 2>&1 || true
  for pid in ${PF_PIDS[@]+"${PF_PIDS[@]}"}; do
    kill "${pid}" 2>/dev/null || true
  done
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${ISO_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# RFC 3339 with milliseconds. A stamp truncated to the second lands up to a
# second away from the window it is meant to open, and the window assertion
# compares exact milliseconds.
rfc3339() {
  python3 -c "
import datetime, sys
ms = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc)
      .strftime('%Y-%m-%dT%H:%M:%S.') + f'{ms % 1000:03d}Z')
" "$1"
}

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# One Alertmanager delivery, the only shape the intake accepts. endsAt is
# Alertmanager's zero time, which is what a firing alert carries.
alert_body() {  # $1 = service, $2 = kind, $3 = namespace, $4 = startsAt, $5 = summary
  python3 -c "
import json, sys
service, kind, namespace, starts, summary = sys.argv[1:6]
print(json.dumps({'version': '4', 'alerts': [{
    'status': 'firing',
    'labels': {'service': service, 'perf_sentinel_kind': kind, 'namespace': namespace},
    'annotations': {'summary': summary},
    'startsAt': starts,
    'endsAt': '0001-01-01T00:00:00Z',
}]}))
" "$1" "$2" "$3" "$4" "$5"
}

# $1 = method, $2 = path, $3 = body ("" for none), $4 = key ("" for none).
# Prints the HTTP code, leaves the body in ${TMP_DIR}/body.
daemon_api() {
  local args=(-s -o "${TMP_DIR}/body" -w '%{http_code}' -X "$1")
  [ -n "${3:-}" ] && args+=(-H "content-type: application/json" -d "$3")
  [ -n "${4:-}" ] && args+=(-H "X-API-Key: $4")
  curl "${args[@]}" "http://127.0.0.1:${DAEMON_PORT}$2"
}

# $1 = method, $2 = path. Prints the HTTP code, body in ${TMP_DIR}/body. The
# Hub's read API takes no key, only the daemon side of the chain is gated.
hub_api() {
  curl -s -o "${TMP_DIR}/body" -w '%{http_code}' -X "$1" "http://127.0.0.1:${HUB_PORT}$2"
}

# Reads the fleet now instead of waiting out PollInterval. The gate admits two
# concurrent reads and answers 503 past that, so a run alongside an open
# incidents screen retries rather than failing.
hub_refresh() {  # $1 = optional query string
  local i code
  for i in $(seq 1 10); do
    code="$(hub_api POST "/api/incidents/refresh${1:-}")"
    [ "${code}" = "200" ] && return 0
    sleep 2
  done
  fail "the Hub refused every refresh (last HTTP ${code}): $(head -c 200 "${TMP_DIR}/body")"
  return 1
}

# Writes the row carrying $2 out of the listing in $1, as a single object, so
# jqp reads a listing row and a single-incident body the same way. Returns 1
# when the id is absent, which is a verdict on its own in several legs.
row_of() {  # $1 = json file, $2 = incident id
  python3 - "$1" "$2" "${TMP_DIR}/row.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
match = [row for row in rows if row.get("id") == sys.argv[2]]
if not match:
    sys.exit(1)
json.dump(match[0], open(sys.argv[3], "w"))
PY
}

# Reuse a forward that already answers rather than binding a second one on the
# same port: the second bind fails while the probe still passes, served by the
# first, so the scenario would read healthy with its own forward dead and
# cleanup would kill a process that never served anything.
# scripts/port-forward.sh reconnects its own forwards after a rollout, which is
# why the wait is generous when this is called again after one.
ensure_forward() {  # $1 = service, $2 = local port, $3 = remote port, $4 = probe path, $5 = wait seconds
  local i
  for i in $(seq 1 "$(( $5 * 2 ))"); do
    curl -sf "http://127.0.0.1:$2$4" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  kubectl -n "${NS}" port-forward "svc/$1" "$2:$3" >"${TMP_DIR}/pf-$1.log" 2>&1 &
  PF_PIDS+=("$!")
  for i in $(seq 1 40); do
    curl -sf "http://127.0.0.1:$2$4" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

# === A. Pre-flight ===
step "0. Pre-flight"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"

# A worktree run points this at the checkout that owns the keys rather than copying them.
KEY_DIR="${HUB_INCIDENTS_KEY_DIR:-${LAB_ROOT}}"
WRITE_KEY_FILE="${KEY_DIR}/.perf-sentinel-incidents.key"
READ_KEY_FILE="${KEY_DIR}/.perf-sentinel-read.key"
[ -f "${WRITE_KEY_FILE}" ] || die "no incidents write key at ${WRITE_KEY_FILE}. Run: make up (scripts/bootstrap.sh generates it)"
[ -f "${READ_KEY_FILE}" ] || die "no read key at ${READ_KEY_FILE}. Run: make up (scripts/bootstrap.sh generates it)"
WRITE_KEY="$(cat "${WRITE_KEY_FILE}")"
READ_KEY="$(cat "${READ_KEY_FILE}")"
[ "${WRITE_KEY}" != "${READ_KEY}" ] || die "the two keys are equal, the daemon refuses that pair. Delete both and re-run scripts/bootstrap.sh"

kubectl -n "${NS}" get deploy/perf-sentinel-hub >/dev/null 2>&1 \
  || die "no Hub in the cluster. Run: make seed-hub-local"
kubectl -n "${NS}" rollout status deploy/perf-sentinel-hub --timeout=120s >/dev/null \
  || die "the Hub is not ready"
kubectl -n "${NS}" rollout status deploy/perf-sentinel-daemon --timeout=120s >/dev/null \
  || die "the daemon is not ready"
ok "both deployments are rolled out"

ensure_forward perf-sentinel-hub "${HUB_PORT}" 8080 /health/ready 2 \
  || die "the Hub's /health/ready never answered on ${HUB_PORT} (scripts/port-forward.sh start)"
ensure_forward perf-sentinel-daemon "${DAEMON_PORT}" 14318 /health 2 \
  || die "the daemon's /health never answered on ${DAEMON_PORT} (scripts/port-forward.sh start)"
ok "both forwards answer"

# The committed manifest pins the published Hub, which serves no incidents
# route before 0.1.6. Ask the route itself rather than a version string: a Hub
# that predates it answers 404 and there is nothing to mirror into.
HUB_PROBE="$(hub_api GET "/api/incidents?limit=1")"
[ "${HUB_PROBE}" = "200" ] \
  || die "the Hub answered HTTP ${HUB_PROBE} on GET /api/incidents. This route needs a Hub from 0.1.6 and the committed manifest pins a newer one, so the running pod is stale. Run: kubectl apply -f manifests/perf-sentinel-hub.yaml"
ok "the Hub serves GET /api/incidents"

CFG="$(curl -sf "http://127.0.0.1:${DAEMON_PORT}/api/config")" || die "the daemon's /api/config is unreachable"
CFG_INC="$(printf '%s' "${CFG}" | jqp "str(d.get('incidents_enabled', 'absent')).lower()")"
CFG_READ="$(printf '%s' "${CFG}" | jqp "str(d.get('read_api_key_set', 'absent')).lower()")"
TTL_MS="$(printf '%s' "${CFG}" | jqp "d['trace_ttl_ms']")"
[ "${CFG_INC}" = "true" ] \
  || die "the daemon reports incidents_enabled=${CFG_INC}. [daemon.incidents] is off, or the pod predates 0.20.0"
[ "${CFG_READ}" = "true" ] \
  || die "the daemon reports read_api_key_set=${CFG_READ}. PERF_SENTINEL_READ_API_KEY resolved to nothing, so the Hub could never read the ring"
ok "incidents_enabled=true, read_api_key_set=true, trace_ttl_ms=${TTL_MS}"
record "pre-flight" PASS "incidents enabled, read key set, ttl ${TTL_MS} ms"

# === B. The capture ===
step "1. The daemon freezes the window an alert names"
FINDINGS_URL="http://127.0.0.1:${DAEMON_PORT}/api/findings?service=${SERVICE}"
# Bounded by the window the freeze reads, not by the whole ring: a re-run more
# than lookback_ms after an aborted one would otherwise count stale rows, skip
# the seed and freeze nothing.
count_service_findings() {
  curl -sf "${FINDINGS_URL}&since_ms=$(( $(now_ms) - LOOKBACK_MS ))" 2>/dev/null \
    | jqp 'len(d)' 2>/dev/null || echo 0
}
SEEDED="$(count_service_findings)"
if [ "${SEEDED}" = "0" ]; then
  step "    no finding for ${SERVICE} yet, driving tracegen at the shared daemon"
  docker image inspect lab-tracegen:1 >/dev/null 2>&1 \
    || die "no lab-tracegen:1 image. Run: make seed-tracegen"
  kubectl -n "${NS}" delete job "${SCENARIO}-seed" --ignore-not-found >/dev/null 2>&1
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${SCENARIO}-seed
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: {app: tracegen}
    spec:
      restartPolicy: Never
      containers:
        - name: tracegen
          image: lab-tracegen:1
          imagePullPolicy: Never
          args:
            - "--endpoint=http://perf-sentinel-daemon.${NS}.svc.cluster.local:14318"
            - "--protocol=http-pb"
            - "--services=1"
            - "--service-prefix=incmirror"
            - "--run-nonce=probe"
            - "--tps=25"
            - "--duration=15"
            - "--mix=n_plus_one:100"
EOF
  kubectl -n "${NS}" wait --for=condition=complete "job/${SCENARIO}-seed" --timeout=120s >/dev/null 2>&1 \
    || fail "the tracegen job did not complete: $(kubectl -n "${NS}" logs "job/${SCENARIO}-seed" --tail=5 2>&1)"
  # A finding exists only once its trace window has closed, one trace_ttl_ms
  # after the last span of the trace.
  for _ in $(seq 1 40); do
    SEEDED="$(count_service_findings)"
    [ "${SEEDED}" != "0" ] && break
    sleep 5
  done
  kubectl -n "${NS}" delete job "${SCENARIO}-seed" --ignore-not-found >/dev/null 2>&1
fi
[ "${SEEDED}" != "0" ] && [ "${SEEDED}" -gt 0 ] 2>/dev/null \
  || die "the daemon holds no finding for ${SERVICE}, so an alert on it would freeze an empty window"
ok "${SEEDED} finding(s) in the ring for ${SERVICE}"

AT_MS="$(now_ms)"
STARTS="$(rfc3339 "${AT_MS}")"
INTAKE_CODE="$(daemon_api POST /api/incidents \
  "$(alert_body "${SERVICE}" oom_kill "${ALERT_NS}" "${STARTS}" "container memory limit reached")" \
  "${WRITE_KEY}")"
INTAKE="$(cat "${TMP_DIR}/body")"
if [ "${INTAKE_CODE}" = "200" ] && [ "$(printf '%s' "${INTAKE}" | jqp "d['recorded']")" = "1" ]; then
  ok "the delivery was accepted, recorded=1 (${INTAKE})"
  record "the write key records an incident" PASS "recorded=1"
else
  fail "HTTP ${INTAKE_CODE}, body ${INTAKE}"
  record "the write key records an incident" FAIL "HTTP ${INTAKE_CODE}"
fi

# The discriminator for leg D, posted here so the single refresh in leg C
# carries both incidents to the Hub.
GHOST_CODE="$(daemon_api POST /api/incidents \
  "$(alert_body "${GHOST_SERVICE}" deploy "${GHOST_NS}" "${STARTS}" "rollout started")" \
  "${WRITE_KEY}")"
if [ "${GHOST_CODE}" = "200" ]; then
  ok "the discriminator incident is recorded, leg D has something to exclude"
  record "the discriminator incident is posted" PASS "${GHOST_NS}/${GHOST_SERVICE}, kind deploy"
else
  fail "the second incident was refused with HTTP ${GHOST_CODE}, leg D would have nothing to exclude"
  record "the discriminator incident is posted" FAIL "HTTP ${GHOST_CODE}"
fi

# The read key the Hub carries opens the listing and nothing else. Asserted
# rather than assumed, because it is the whole reason the Hub is given that key
# instead of the one the alerting posts with.
READ_POST_CODE="$(daemon_api POST /api/incidents \
  "$(alert_body "${SERVICE}" oom_kill "${ALERT_NS}" "${STARTS}" "posted with the read key")" \
  "${READ_KEY}")"
if [ "${READ_POST_CODE}" = "401" ]; then
  ok "the read key is refused on POST /api/incidents"
  record "the read key never writes" PASS "POST answered 401"
else
  fail "the read key posted an incident, HTTP ${READ_POST_CODE}"
  record "the read key never writes" FAIL "POST answered ${READ_POST_CODE}"
fi

daemon_api GET "/api/incidents?service=${SERVICE}" "" "${READ_KEY}" >/dev/null
INCIDENT_ID="$(jqp "next((r['id'] for r in d if r['at_ms'] == ${AT_MS}), 'absent')" < "${TMP_DIR}/body")"
if [ "${INCIDENT_ID}" = "absent" ]; then
  die "the daemon lists no incident at at_ms=${AT_MS} for ${SERVICE} under the read key: $(head -c 300 "${TMP_DIR}/body")"
fi
row_of "${TMP_DIR}/body" "${INCIDENT_ID}" || die "the incident vanished between two reads"
D_SERVICE="$(jqp "d['service']" < "${TMP_DIR}/row.json")"
D_NAMESPACE="$(jqp "d.get('namespace', 'absent')" < "${TMP_DIR}/row.json")"
D_KIND="$(jqp "d['kind']" < "${TMP_DIR}/row.json")"
D_FROM="$(jqp "d['window_from_ms']" < "${TMP_DIR}/row.json")"
D_TO="$(jqp "d['window_to_ms']" < "${TMP_DIR}/row.json")"
D_FROZEN="$(jqp "len(d['findings'])" < "${TMP_DIR}/row.json")"
EXPECT_FROM=$((AT_MS - LOOKBACK_MS))
EXPECT_TO=$((AT_MS + 2 * TTL_MS))

if [ "${D_SERVICE}" = "${SERVICE}" ] && [ "${D_FROM}" = "${EXPECT_FROM}" ] && [ "${D_TO}" = "${EXPECT_TO}" ] \
   && [ "${D_FROZEN}" -ge 1 ] && [ "${D_NAMESPACE}" = "${ALERT_NS}" ] && [ "${D_KIND}" = "oom_kill" ]; then
  ok "incident ${INCIDENT_ID}: ${D_FROZEN} finding(s) frozen over [${D_FROM}, ${D_TO}], namespace ${D_NAMESPACE}"
  record "the read key reads the frozen window" PASS "${D_FROZEN} finding(s), [at - ${LOOKBACK_MS}, at + 2 x ttl], namespace ${D_NAMESPACE}"
else
  fail "service ${D_SERVICE}, kind ${D_KIND}, namespace ${D_NAMESPACE}, frozen ${D_FROZEN}"
  fail "window [${D_FROM}, ${D_TO}], expected [${EXPECT_FROM}, ${EXPECT_TO}]"
  record "the read key reads the frozen window" FAIL "frozen=${D_FROZEN}, window [${D_FROM}, ${D_TO}]"
fi

# === C. The mirror ===
step "2. The Hub mirrors the record, findings included"
# The daemon merges the traces that were live at the incident into the record
# one settle pass later, at at_ms + 3 x trace_ttl_ms. Reading either side
# before that races the merge and the two copies would differ for a reason
# that is not a bug. Wait it out once, here, and every later leg compares two
# settled records.
SETTLE_SLEEP="$(python3 -c "
import time
due = (${AT_MS} + 3 * ${TTL_MS} + 5000) / 1000
print(max(0.0, due - time.time()))
")"
step "    waiting ${SETTLE_SLEEP}s for the daemon's settle pass to close the record"
sleep "${SETTLE_SLEEP}"

daemon_api GET "/api/incidents?service=${SERVICE}" "" "${READ_KEY}" >/dev/null
row_of "${TMP_DIR}/body" "${INCIDENT_ID}" || die "the daemon lost the incident before the Hub read it"
cp "${TMP_DIR}/row.json" "${TMP_DIR}/daemon-incident.json"
D_COUNT="$(jqp "len(d['findings'])" < "${TMP_DIR}/daemon-incident.json")"
D_SIGS="$(jqp "','.join(sorted(f['finding']['signature'] for f in d['findings']))" < "${TMP_DIR}/daemon-incident.json")"
D_OLDEST="$(jqp "d.get('oldest_finding_ms', 'absent')" < "${TMP_DIR}/daemon-incident.json")"
# IncidentWriter.Capture: at or below the window's start the ring still reached
# the whole window, above it part of it had been evicted, absent means empty.
if [ "${D_OLDEST}" = "absent" ]; then
  EXPECT_CAPTURE="empty"
elif [ "${D_OLDEST}" -le "${EXPECT_FROM}" ]; then
  EXPECT_CAPTURE="complete"
else
  EXPECT_CAPTURE="partial"
fi

# Straddle the ten-second floor the way legs E and G do. A background poll that
# just read this source makes the route skip it and answer from the store, so a
# single refresh can serve the copy taken before the settle pass landed.
hub_refresh || die "the Hub never read the fleet, the rest of the scenario would assert on a stale copy"
sleep "${REFRESH_DEBOUNCE_S}"
hub_refresh || die "the Hub never read the fleet, the rest of the scenario would assert on a stale copy"
cp "${TMP_DIR}/body" "${TMP_DIR}/hub-listing.json"
if row_of "${TMP_DIR}/hub-listing.json" "${INCIDENT_ID}"; then
  H_SOURCE="$(jqp "d.get('source_id', 'absent')" < "${TMP_DIR}/row.json")"
  H_ENV="$(jqp "d.get('environment', 'absent')" < "${TMP_DIR}/row.json")"
  H_COUNT="$(jqp "d.get('finding_count', 'absent')" < "${TMP_DIR}/row.json")"
  H_CAPTURE="$(jqp "d.get('capture', 'absent')" < "${TMP_DIR}/row.json")"
  H_NAMESPACE="$(jqp "d.get('namespace', 'absent')" < "${TMP_DIR}/row.json")"
  H_HAS_FINDINGS="$(jqp "'yes' if 'findings' in d else 'no'" < "${TMP_DIR}/row.json")"
  if [ "${H_SOURCE}" = "${SOURCE_ID}" ] && [ "${H_ENV}" = "${ENVIRONMENT}" ] \
     && [ "${H_COUNT}" = "${D_COUNT}" ] && [ "${H_CAPTURE}" = "${EXPECT_CAPTURE}" ] \
     && [ "${H_NAMESPACE}" = "${ALERT_NS}" ] && [ "${H_HAS_FINDINGS}" = "no" ]; then
    ok "listed under ${H_SOURCE}/${H_ENV}, finding_count=${H_COUNT}, capture=${H_CAPTURE}, no findings inline"
    record "the listing carries the record, not its findings" PASS "source ${H_SOURCE}, count ${H_COUNT}, capture ${H_CAPTURE}"
  else
    fail "source_id=${H_SOURCE}, environment=${H_ENV}, finding_count=${H_COUNT} (daemon ${D_COUNT})"
    fail "capture=${H_CAPTURE} (expected ${EXPECT_CAPTURE} from oldest_finding_ms=${D_OLDEST}), namespace=${H_NAMESPACE}, findings inline: ${H_HAS_FINDINGS}"
    record "the listing carries the record, not its findings" FAIL "count ${H_COUNT} vs ${D_COUNT}, capture ${H_CAPTURE}"
  fi
else
  fail "the Hub lists no incident ${INCIDENT_ID} after reading the fleet"
  record "the listing carries the record, not its findings" FAIL "incident absent from the Hub"
fi

HUB_ONE_CODE="$(hub_api GET "/api/incidents/${INCIDENT_ID}")"
if [ "${HUB_ONE_CODE}" = "200" ]; then
  H_ONE_COUNT="$(jqp "len(d.get('findings', []))" < "${TMP_DIR}/body")"
  H_SIGS="$(jqp "','.join(sorted(f['finding']['signature'] for f in d.get('findings', [])))" < "${TMP_DIR}/body")"
else
  H_ONE_COUNT="absent"
  H_SIGS="absent"
fi
if [ "${H_ONE_COUNT}" = "${D_COUNT}" ] && [ "${H_SIGS}" = "${D_SIGS}" ] && [ "${D_COUNT}" -ge 1 ]; then
  ok "${H_ONE_COUNT} finding(s) come back whole, every signature the daemon froze and no other"
  record "the frozen findings survive the copy" PASS "${H_ONE_COUNT} signature(s) identical to the daemon's"
else
  fail "HTTP ${HUB_ONE_CODE}, the Hub returns ${H_ONE_COUNT} finding(s) against the daemon's ${D_COUNT}"
  fail "a signature set that differs means the Hub re-derived the window instead of copying it"
  record "the frozen findings survive the copy" FAIL "${H_ONE_COUNT} vs ${D_COUNT} finding(s)"
fi

# === D. The filters ===
step "3. Every filter narrows, and a closed one refuses an unknown value"
# An empty incidents screen is the answer an operator hopes for, so a typo in a
# filter must not be able to produce it. A kind, a source id and an environment
# are configuration the Hub knows in full, so an unknown value is a bad request.
# A service or a namespace is free text the fleet decides, so an unknown one is
# an honest empty page.
filter_holds() {  # $1 = query string, $2 = python predicate over one row, $3 = id that must be present
  local code
  code="$(hub_api GET "/api/incidents?$1")"
  [ "${code}" = "200" ] || { echo "http ${code}"; return 1; }
  python3 - "${TMP_DIR}/body" "$3" <<PY || { echo "rows do not hold"; return 1; }
import json, sys
rows = json.load(open(sys.argv[1]))
assert rows, "empty page"
assert all($2 for d in rows), "a row escaped the filter"
assert any(row["id"] == sys.argv[2] for row in rows), "the expected incident is missing"
PY
  echo "ok"
}

FILTER_NOTE=""
FILTER_OK=1
for probe in \
  "service=${SERVICE}|d['service'] == '${SERVICE}'" \
  "namespace=${ALERT_NS}|d.get('namespace') == '${ALERT_NS}'" \
  "kind=oom_kill|d['kind'] == 'oom_kill'" \
  "source_id=${SOURCE_ID}|d['source_id'] == '${SOURCE_ID}'"; do
  query="${probe%%|*}"
  predicate="${probe#*|}"
  result="$(filter_holds "${query}" "${predicate}" "${INCIDENT_ID}")" || true
  if [ "${result}" = "ok" ]; then
    ok "${query} narrows to rows that all match, ours included"
  else
    FILTER_OK=0
    FILTER_NOTE="${FILTER_NOTE}${query} (${result}) "
    fail "${query}: ${result}"
  fi
done

MISS_CODE="$(hub_api GET "/api/incidents?service=${SERVICE}-no-such-thing")"
MISS_ROWS="$(jqp 'len(d)' < "${TMP_DIR}/body" 2>/dev/null || echo absent)"
if [ "${MISS_CODE}" = "200" ] && [ "${MISS_ROWS}" = "0" ]; then
  ok "a service nobody reports is an empty page, not an error"
else
  FILTER_OK=0
  FILTER_NOTE="${FILTER_NOTE}unknown-service=HTTP ${MISS_CODE}/${MISS_ROWS} rows "
  fail "an unknown service answered HTTP ${MISS_CODE} with ${MISS_ROWS} row(s)"
fi

CLOSED_NOTE=""
CLOSED_OK=1
for query in "kind=meltdown" "environment=nowhere" "source_id=nowhere"; do
  code="$(hub_api GET "/api/incidents?${query}")"
  if [ "${code}" = "400" ]; then
    ok "${query} answers 400: a typo cannot read as an empty incidents screen"
  else
    CLOSED_OK=0
    CLOSED_NOTE="${CLOSED_NOTE}${query}=HTTP ${code} "
    fail "${query} answered HTTP ${code}, expected 400"
  fi
done

if [ "${FILTER_OK}" = "1" ]; then
  record "the open filters narrow" PASS "service, namespace, kind and source_id, plus an empty page on a miss"
else
  record "the open filters narrow" FAIL "${FILTER_NOTE}"
fi
if [ "${CLOSED_OK}" = "1" ]; then
  record "the closed filters refuse" PASS "unknown kind, environment and source_id all 400"
else
  record "the closed filters refuse" FAIL "${CLOSED_NOTE}"
fi

# === E. Failure isolation ===
step "4. A refused read key isolates itself from the findings"
# The Hub reads its source list once at startup, so the wrong key has to arrive
# through a rollout. Patching this Deployment's own env var is the narrowest
# way to do it: the shared Secret keeps the value both sides agree on, so the
# daemon and every other scenario see nothing, and the trap puts the
# secretKeyRef back whatever happens here.
hub_source_field() {  # $1 = python expression over the lab-daemon source
  curl -sf "http://127.0.0.1:${HUB_PORT}/api/sources" 2>/dev/null | python3 -c "
import json, sys
rows = json.load(sys.stdin)
d = next((r for r in rows if r.get('id') == '${SOURCE_ID}'), None)
print('absent' if d is None else $1)
" 2>/dev/null || echo absent
}
FINDINGS_BEFORE="$(curl -sf "http://127.0.0.1:${HUB_PORT}/api/findings?limit=1000" 2>/dev/null | jqp 'len(d)' 2>/dev/null || echo 0)"
PATCH_AT_MS="$(now_ms)"

kubectl -n "${NS}" patch deploy/perf-sentinel-hub --type=strategic -p "${HUB_ENV_WRONG}" >/dev/null
HUB_KEY_PATCHED=1
kubectl -n "${NS}" rollout status deploy/perf-sentinel-hub --timeout=180s >/dev/null \
  || die "the Hub did not come back with the wrong key, the trap will restore the real one"
ensure_forward perf-sentinel-hub "${HUB_PORT}" 8080 /health/ready 90 \
  || die "the Hub's forward never came back after the rollout"

# The poll runs once at startup and reads the incidents ring inside it, so the
# state is usually already filed by the time the refresh below lands.
INC_STATE="absent"
for _ in $(seq 1 20); do
  INC_STATE="$(hub_source_field "d.get('incidents_state', 'absent')")"
  [ "${INC_STATE}" = "unauthorized" ] && break
  hub_refresh >/dev/null 2>&1 || true
  sleep 3
done
REACHABLE="$(hub_source_field "str(d.get('reachable', 'absent')).lower()")"
UNREACHABLE_SINCE="$(hub_source_field "'null' if 'unreachable_since_ms' in d and d['unreachable_since_ms'] is None else 'absent'")"
LAST_SUCCESS="$(hub_source_field "d.get('last_success_ms') or 0")"
FINDINGS_AFTER="$(curl -sf "http://127.0.0.1:${HUB_PORT}/api/findings?limit=1000" 2>/dev/null | jqp 'len(d)' 2>/dev/null || echo 0)"

if [ "${INC_STATE}" = "unauthorized" ] && [ "${REACHABLE}" = "true" ] \
   && [ "${UNREACHABLE_SINCE}" = "null" ] && [ "${LAST_SUCCESS}" -ge "${PATCH_AT_MS}" ] \
   && [ "${FINDINGS_AFTER}" -ge "${FINDINGS_BEFORE}" ]; then
  ok "incidents_state=unauthorized while the source stays reachable and still reports ${FINDINGS_AFTER} finding(s)"
  record "a refused read key stays in its lane" PASS "incidents_state=unauthorized, reachable, ${FINDINGS_AFTER} findings"
else
  fail "incidents_state=${INC_STATE}, reachable=${REACHABLE}, unreachable_since_ms=${UNREACHABLE_SINCE}"
  fail "last_success_ms=${LAST_SUCCESS} (patched at ${PATCH_AT_MS}), findings ${FINDINGS_BEFORE} -> ${FINDINGS_AFTER}"
  record "a refused read key stays in its lane" FAIL "incidents_state=${INC_STATE}, reachable=${REACHABLE}"
fi

restore_hub_key
ensure_forward perf-sentinel-hub "${HUB_PORT}" 8080 /health/ready 90 \
  || die "the Hub's forward never came back after the key was restored"
INC_STATE_BACK="absent"
for _ in $(seq 1 20); do
  INC_STATE_BACK="$(hub_source_field "d.get('incidents_state', 'absent')")"
  [ "${INC_STATE_BACK}" = "ok" ] && break
  hub_refresh >/dev/null 2>&1 || true
  sleep 3
done
if [ "${INC_STATE_BACK}" = "ok" ]; then
  ok "the real key is back and the source reads ok again"
  record "the read key is restored" PASS "incidents_state back to ok"
else
  fail "incidents_state is ${INC_STATE_BACK} after the restore, the shared pair is left degraded"
  record "the read key is restored" FAIL "incidents_state=${INC_STATE_BACK}"
fi

# === F. The archive replay ===
step "5. The shared daemon replays its incident archive at startup"
# The shared daemon keeps [daemon.incidents] archive_path on the
# perf-sentinel-acks PVC, and since 0.24.0 it reloads the ring from that file
# before it serves, last record per id winning. So a restart brings back the
# settled record, signature for signature, rather than an empty ring.
kubectl -n "${NS}" rollout restart deploy/perf-sentinel-daemon >/dev/null
kubectl -n "${NS}" rollout status deploy/perf-sentinel-daemon --timeout=240s >/dev/null \
  || die "the daemon did not come back after the restart"
ensure_forward perf-sentinel-daemon "${DAEMON_PORT}" 14318 /health 90 \
  || die "the daemon's forward never came back after the restart"

daemon_api GET "/api/incidents?service=${SERVICE}" "" "${READ_KEY}" >/dev/null
if row_of "${TMP_DIR}/body" "${INCIDENT_ID}"; then
  REPLAY_COUNT="$(jqp "len(d['findings'])" < "${TMP_DIR}/row.json")"
  REPLAY_SIGS="$(jqp "','.join(sorted(f['finding']['signature'] for f in d['findings']))" < "${TMP_DIR}/row.json")"
else
  REPLAY_COUNT="absent"
  REPLAY_SIGS="absent"
fi
if [ "${REPLAY_COUNT}" = "${D_COUNT}" ] && [ "${REPLAY_SIGS}" = "${D_SIGS}" ]; then
  ok "the restarted daemon lists ${INCIDENT_ID} again with its ${REPLAY_COUNT} frozen finding(s)"
  record "the shared daemon replays its archive" PASS "${REPLAY_COUNT} finding(s) back after a restart"
else
  fail "after the restart the daemon lists ${REPLAY_COUNT} finding(s) for ${INCIDENT_ID} against ${D_COUNT} frozen"
  record "the shared daemon replays its archive" FAIL "replayed ${REPLAY_COUNT} vs ${D_COUNT}"
fi

# === G. Retention and the richest copy, on an isolated pair ===
step "6. The copy outlives the ring, and a poorer capture never replaces it"
# The shared daemon cannot lose its ring any more (leg F), so this leg stands
# up its own daemon and Hub, in the shape of scenarios/hub-source-reachability:
# same images, no archive_path, so a restart is a real loss of evidence.
DAEMON_IMAGE="$(kubectl -n "${NS}" get deploy/perf-sentinel-daemon -o jsonpath='{.spec.template.spec.containers[0].image}')"
HUB_IMAGE="$(kubectl -n "${NS}" get deploy/perf-sentinel-hub -o jsonpath='{.spec.template.spec.containers[0].image}')"
# Cleanup deletes with --wait=false, so a rerun can land while the previous
# namespace is still terminating. Creating into one is Forbidden, not a retry.
for _ in $(seq 1 60); do
  [ "$(kubectl get namespace "${ISO_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Terminating" ] || break
  sleep 2
done
kubectl create namespace "${ISO_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# The lab's own two keys, copied: they already satisfy the daemon's rule that
# the read key differs from the write key.
kubectl -n "${ISO_NS}" create secret generic api-keys \
  --from-literal=incidents-api-key="${WRITE_KEY}" --from-literal=read-api-key="${READ_KEY}" \
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
    trace_ttl_ms = ${ISO_TTL_MS}
    environment = "staging"

    [daemon.ack]
    enabled = false

    # No archive_path: the ring is the only copy, and it dies with the pod.
    [daemon.incidents]
    enabled = true
    lookback_ms = ${LOOKBACK_MS}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: daemon, namespace: ${ISO_NS}}
spec:
  replicas: 1
  # Recreate, so the old pod is gone before the new one serves and the ring
  # read after the restart cannot come from the pod that held the incident.
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
          args: [watch, --config, /etc/perf-sentinel/config.toml]
          ports: [{name: http, containerPort: 14318}]
          env:
            - name: PERF_SENTINEL_INCIDENTS_API_KEY
              valueFrom: {secretKeyRef: {name: api-keys, key: incidents-api-key}}
            - name: PERF_SENTINEL_READ_API_KEY
              valueFrom: {secretKeyRef: {name: api-keys, key: read-api-key}}
          volumeMounts:
            - {name: config, mountPath: /etc/perf-sentinel, readOnly: true}
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
      "PollInterval": "00:01:00",
      "HttpTimeout": "00:00:05",
      "Retention": "180.00:00:00",
      "ResolutionGrace": "01:00:00",
      "MaxReadLimit": 10000,
      "Sources": [{
        "Id": "${SOURCE_ID}", "Name": "isolated lab daemon", "Environment": "${ENVIRONMENT}",
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
kubectl -n "${ISO_NS}" rollout status deploy/daemon --timeout=180s >/dev/null \
  || die "the isolated daemon did not become ready: $(kubectl -n "${ISO_NS}" logs deploy/daemon --tail=20 2>&1)"
kubectl -n "${ISO_NS}" rollout status deploy/hub --timeout=180s >/dev/null \
  || die "the isolated Hub did not become ready: $(kubectl -n "${ISO_NS}" logs deploy/hub --tail=20 2>&1)"

# A forward of our own, never reused: its pid is what lets the daemon restart
# below drop it, since a forward to a deleted pod dies without exiting.
iso_forward() {  # $1 = service, $2 = local port, $3 = remote port, $4 = probe path
  local i
  kubectl -n "${ISO_NS}" port-forward "svc/$1" "$2:$3" >"${TMP_DIR}/pf-iso-$1.log" 2>&1 &
  LAST_PF="$!"
  PF_PIDS+=("${LAST_PF}")
  disown "${LAST_PF}" 2>/dev/null || true
  for i in $(seq 1 40); do
    curl -sf "http://127.0.0.1:$2$4" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
iso_forward hub "${ISO_HUB_PORT}" 8080 /health/ready || die "the isolated Hub never answered on ${ISO_HUB_PORT}"
iso_forward daemon "${ISO_DAEMON_PORT}" 14318 /health || die "the isolated daemon never answered on ${ISO_DAEMON_PORT}"
ISO_DAEMON_PF="${LAST_PF}"
# Every helper above reads these two, so the rest of the leg talks to the pair.
HUB_PORT="${ISO_HUB_PORT}"
DAEMON_PORT="${ISO_DAEMON_PORT}"
ok "isolated pair in ${ISO_NS}: daemon ${DAEMON_IMAGE} without an archive, Hub ${HUB_IMAGE}"

iso_findings() {
  daemon_api GET "/api/findings?service=${SERVICE}" "" "${READ_KEY}" >/dev/null
  jqp 'len(d)' < "${TMP_DIR}/body" 2>/dev/null || echo 0
}
kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: seed, namespace: ${ISO_NS}}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: {app: tracegen}
    spec:
      restartPolicy: Never
      containers:
        - name: tracegen
          image: lab-tracegen:1
          imagePullPolicy: Never
          args:
            - "--endpoint=http://daemon.${ISO_NS}.svc.cluster.local:14318"
            - "--protocol=http-pb"
            - "--services=1"
            - "--service-prefix=incmirror"
            - "--run-nonce=probe"
            - "--tps=25"
            - "--duration=15"
            - "--mix=n_plus_one:100"
EOF
kubectl -n "${ISO_NS}" wait --for=condition=complete job/seed --timeout=120s >/dev/null 2>&1 \
  || fail "the tracegen job did not complete: $(kubectl -n "${ISO_NS}" logs job/seed --tail=5 2>&1)"
ISO_SEEDED=0
for _ in $(seq 1 30); do
  ISO_SEEDED="$(iso_findings)"
  [ "${ISO_SEEDED}" != "0" ] && break
  sleep 2
done
[ "${ISO_SEEDED}" -gt 0 ] 2>/dev/null || die "the isolated daemon holds no finding for ${SERVICE}"
ok "${ISO_SEEDED} finding(s) in the isolated ring for ${SERVICE}"

ISO_AT_MS="$(now_ms)"
ISO_STARTS="$(rfc3339 "${ISO_AT_MS}")"
ISO_ALERT="$(alert_body "${SERVICE}" oom_kill "${ALERT_NS}" "${ISO_STARTS}" "container memory limit reached")"
ISO_INTAKE="$(daemon_api POST /api/incidents "${ISO_ALERT}" "${WRITE_KEY}")"
[ "${ISO_INTAKE}" = "200" ] || die "the isolated daemon refused the alert with HTTP ${ISO_INTAKE}: $(cat "${TMP_DIR}/body")"
# Same settle wait as leg C, at this daemon's ttl.
sleep "$(python3 -c "import time; print(max(0.0, (${ISO_AT_MS} + 3 * ${ISO_TTL_MS} + 5000) / 1000 - time.time()))")"
daemon_api GET "/api/incidents?service=${SERVICE}" "" "${READ_KEY}" >/dev/null
ISO_ID="$(jqp "next((r['id'] for r in d if r['at_ms'] == ${ISO_AT_MS}), 'absent')" < "${TMP_DIR}/body")"
[ "${ISO_ID}" != "absent" ] || die "the isolated daemon lists no incident at at_ms=${ISO_AT_MS}"
row_of "${TMP_DIR}/body" "${ISO_ID}" || die "the isolated incident vanished between two reads"
ISO_COUNT="$(jqp "len(d['findings'])" < "${TMP_DIR}/row.json")"
ISO_SIGS="$(jqp "','.join(sorted(f['finding']['signature'] for f in d['findings']))" < "${TMP_DIR}/row.json")"
[ "${ISO_COUNT}" -ge 1 ] || die "the isolated incident froze no finding, there would be no richer copy to keep"

hub_signatures() {  # prints "<count> <signatures>" for $1 on the Hub, or "absent absent"
  if [ "$(hub_api GET "/api/incidents/$1")" = "200" ]; then
    jqp "str(len(d.get('findings', []))) + ' ' + ','.join(sorted(f['finding']['signature'] for f in d.get('findings', [])))" < "${TMP_DIR}/body"
  else
    echo "absent absent"
  fi
}
# Straddle the debounce like leg C: the Hub's startup poll may just have read
# this source.
hub_refresh || die "the isolated Hub never read its daemon"
sleep "${REFRESH_DEBOUNCE_S}"
hub_refresh || die "the isolated Hub never read its daemon"
ISO_HUB="$(hub_signatures "${ISO_ID}")"
[ "${ISO_HUB}" = "${ISO_COUNT} ${ISO_SIGS}" ] \
  || die "the isolated Hub holds '${ISO_HUB}' before the restart, against the daemon's ${ISO_COUNT} finding(s)"
ok "incident ${ISO_ID}: ${ISO_COUNT} finding(s) frozen and mirrored"

# A refresh answers 200 with the stored listing even when its read of the
# daemon failed, so each verdict below also proves the Hub read the daemon
# after the event: without that, a failed read keeps the copy and passes.
iso_read_since() {  # $1 = epoch ms the Hub's last incidents read must not predate
  hub_source_field "'ok' if d.get('incidents_state') == 'ok' and (d.get('incidents_read_ms') or 0) >= $1 else 'state=%s read_ms=%s' % (d.get('incidents_state'), d.get('incidents_read_ms'))"
}
RESTART_AT_MS="$(now_ms)"
kill "${ISO_DAEMON_PF}" 2>/dev/null || true
kubectl -n "${ISO_NS}" rollout restart deploy/daemon >/dev/null
kubectl -n "${ISO_NS}" rollout status deploy/daemon --timeout=180s >/dev/null \
  || die "the isolated daemon did not come back after the restart"
iso_forward daemon "${ISO_DAEMON_PORT}" 14318 /health || die "the isolated daemon's forward never came back"

daemon_api GET "/api/incidents?service=${SERVICE}" "" "${READ_KEY}" >/dev/null
RING_HOLDS="$(jqp "sum(1 for r in d if r['id'] == '${ISO_ID}')" < "${TMP_DIR}/body" 2>/dev/null || echo absent)"
# Past the debounce, so this refresh really reads the emptied daemon.
sleep "${REFRESH_DEBOUNCE_S}"
hub_refresh || die "the isolated Hub refused to re-read its daemon after the restart"
KEPT="$(hub_signatures "${ISO_ID}")"
READ_AFTER_RESTART="$(iso_read_since "${RESTART_AT_MS}")"
if [ "${RING_HOLDS}" = "0" ] && [ "${KEPT}" = "${ISO_COUNT} ${ISO_SIGS}" ] && [ "${READ_AFTER_RESTART}" = "ok" ]; then
  ok "the daemon's ring lost the incident with its pod, the Hub still serves its ${ISO_COUNT} finding(s)"
  record "the copy outlives the ring" PASS "ring empty, Hub keeps ${ISO_COUNT} finding(s)"
else
  fail "the restarted daemon lists the id ${RING_HOLDS} time(s), the Hub serves '${KEPT%% *}' finding(s) against ${ISO_COUNT}, its read after the restart: ${READ_AFTER_RESTART}"
  record "the copy outlives the ring" FAIL "ring=${RING_HOLDS}, Hub=${KEPT%% *}, read=${READ_AFTER_RESTART}"
fi

# The same envelope again. The id is a hash over service, kind, at_ms and the
# namespace when the alert carries one, which it does here, so the restarted
# daemon captures the SAME incident against a ring that no longer reaches back
# to the window: a real re-capture after an outage, and the poorest one there
# is.
REPOST_AT_MS="$(now_ms)"
POOR_CODE="$(daemon_api POST /api/incidents "${ISO_ALERT}" "${WRITE_KEY}")"
daemon_api GET "/api/incidents?service=${SERVICE}" "" "${READ_KEY}" >/dev/null
POOR_COUNT="$(jqp "next((len(r['findings']) for r in d if r['id'] == '${ISO_ID}'), 'absent')" < "${TMP_DIR}/body")"
sleep "${REFRESH_DEBOUNCE_S}"
hub_refresh || die "the isolated Hub refused the refresh that would have carried the poorer capture"
RICH="$(hub_signatures "${ISO_ID}")"
# last_seen takes the read's stamp on conflict, so a fresh one proves the
# 0-finding row went through the upsert and lost to the stored copy.
LAST_SEEN="$(jqp "d.get('last_seen', 0)" < "${TMP_DIR}/body" 2>/dev/null || echo 0)"
READ_AFTER_REPOST="$(iso_read_since "${REPOST_AT_MS}")"
if [ "${POOR_CODE}" = "200" ] && [ "${POOR_COUNT}" = "0" ] && [ "${RICH}" = "${ISO_COUNT} ${ISO_SIGS}" ] \
  && [ "${READ_AFTER_REPOST}" = "ok" ] && [ "${LAST_SEEN}" -ge "${REPOST_AT_MS}" ] 2>/dev/null; then
  ok "the re-capture froze 0 finding(s) and the Hub kept its ${ISO_COUNT}, which is the whole point of the copy"
  record "a poorer capture never replaces a richer one" PASS "daemon re-captured 0, Hub kept ${ISO_COUNT}"
else
  fail "the re-capture was HTTP ${POOR_CODE} with ${POOR_COUNT} finding(s), the Hub now serves '${RICH%% *}' against ${ISO_COUNT}, last_seen=${LAST_SEEN} against the repost at ${REPOST_AT_MS}, read: ${READ_AFTER_REPOST}"
  record "a poorer capture never replaces a richer one" FAIL "re-capture ${POOR_COUNT}, Hub ${RICH%% *}, last_seen=${LAST_SEEN}, read=${READ_AFTER_REPOST}"
fi

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Daemon: \`$(kubectl -n "${NS}" get deploy/perf-sentinel-daemon -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)\`"
  echo
  echo "Hub: \`$(kubectl -n "${NS}" get deploy/perf-sentinel-hub -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)\`"
  echo
  echo "Source \`${SOURCE_ID}\` (${ENVIRONMENT}), service \`${SERVICE}\`, namespace \`${ALERT_NS}\`, incident \`${INCIDENT_ID}\`."
  echo
  echo "Leg 6 on an isolated pair in namespace \`${ISO_NS}\`, daemon without an archive, incident \`${ISO_ID:-none}\`."
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
