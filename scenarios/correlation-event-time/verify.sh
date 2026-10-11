#!/usr/bin/env bash
# correlation-event-time: the 0.23.0 cross-trace correlator pairs findings on
# their own timestamps, and names the trace on each side of a pair.
#
# Until 0.22.2 every finding of an analysis tick was stamped with the tick
# time, so only findings analysed in the same tick could pair, the lag was
# the gap between ticks, and which side was `source` followed arrival order.
# `correlation-finding` cannot see any of that: it only asserts that some
# pair with some confidence exists after validate-findings, which both
# builds satisfy. This scenario places every trace in time and in its own
# batch, so the answer is exact.
#
# Four services, four rounds 30 s apart in event time, every trace in its
# own batch (1 s TTL, 1.5 s between sends):
#   A at t, B at t + 5 s, sent A then B
#   C at t, D at t + 7 s, sent D then C (the later event arrives first)
#
#   1. Lag. A -> B has median_lag_ms 5000 and C -> D 7000, exactly: the gap
#      between the two findings' first spans, not between two ticks.
#   2. Order. C is the source of C -> D although D arrived first, and no
#      D -> C pair exists.
#   3. Both traces. `source_sample_trace_id` and `sample_trace_id` name the
#      last round's traces of each side, and `/api/explain` opens both.
#   4. Counter-proof on the last published image: the same A/B corpus does
#      not yield a 5000 ms lag there. A leg that passes on both builds proves
#      nothing about the new one.
#   5. `[daemon.correlation] window_minutes = 0` is refused at config load.
#
# Self-contained: local release binary, Docker, python3, curl. No cluster.
set -uo pipefail

SCENARIO="correlation-event-time"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
EMIT="${LAB_ROOT}/tools/tracegen/emit_at.py"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

# The A side of the comparison: the last release that pairs on the analysis
# tick, which 0.23.0 replaced with the finding's own timestamp. It stays below
# 0.23.0. Bumped to the release under test, leg 4 passes on both builds and
# proves nothing.
BASELINE_IMAGE="${BASELINE_IMAGE:-ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.22.2}"
BASELINE_NAME="cet-baseline-$$"

DAEMON_HTTP_PORT="${CET_DAEMON_HTTP_PORT:-14848}"
DAEMON_GRPC_PORT="${CET_DAEMON_GRPC_PORT:-14847}"
BASELINE_HTTP_PORT="${CET_BASELINE_HTTP_PORT:-14858}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
BASELINE_URL="http://127.0.0.1:${BASELINE_HTTP_PORT}"

ROUNDS=4
ROUND_GAP_MS=30000
AB_LAG_MS=5000
CD_LAG_MS=7000
# Wall-clock gap between two sends: above the 1 s TTL plus the analysis tick,
# so each trace is analysed in its own batch.
SEND_GAP_S=1.5

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
rm -f "${REPORT}"

color_blue()   { printf '\033[34m%s\033[0m\n' "$*"; }
color_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
color_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
color_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_yellow "    warn: $*"; }
die()  { color_red "    error: $*"; exit 1; }

FAILURES=0
declare -a RESULTS=()
pass() { ok "$2"; RESULTS+=("$1|PASS|$2"); }
fail() { color_red "    FAIL: $2"; RESULTS+=("$1|FAIL|$2"); FAILURES=$((FAILURES + 1)); }

DAEMON_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null
  docker rm -f "${BASELINE_NAME}" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# --- prerequisites -----------------------------------------------------------

step "Prerequisites"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no release binary at ${PERF_SENTINEL_LOCAL_BIN}, run: cd ${PERF_SENTINEL_REPO_PATH} && cargo build --release --workspace"
command -v docker >/dev/null 2>&1 || die "docker is required: leg 4 compares against ${BASELINE_IMAGE}"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
python3 -c 'import opentelemetry.proto' 2>/dev/null \
  || die "emit_at.py needs opentelemetry-proto: pip install -r ${LAB_ROOT}/tools/tracegen/requirements.txt"
docker pull -q "${BASELINE_IMAGE}" >/dev/null 2>&1 \
  || warn "could not refresh ${BASELINE_IMAGE}, using the local copy"
docker image inspect "${BASELINE_IMAGE}" >/dev/null 2>&1 \
  || die "baseline image unavailable: ${BASELINE_IMAGE}"
VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version 2>/dev/null | awk '{print $2}')"
PRODUCT_COMMIT="$(git -C "${PERF_SENTINEL_REPO_PATH}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ok "under test: ${PERF_SENTINEL_LOCAL_BIN} ${VERSION} (${PRODUCT_COMMIT})"
ok "baseline:   ${BASELINE_IMAGE}"

# --- helpers -----------------------------------------------------------------

write_config() {  # $1 = file, $2 = listen address, $3 = http, $4 = grpc, $5 = window_minutes
  cat > "$1" <<EOF
[daemon]
listen_address = "$2"
listen_port_http = $3
listen_port_grpc = $4
api_enabled = true
# One trace per batch: a short TTL closes each trace before the next send.
trace_ttl_ms = 1000

[daemon.ack]
enabled = false

[daemon.correlation]
enabled = true
window_minutes = $5
# Below the 30 s between rounds, so a finding only pairs within its round
# and every lag sample is the in-round gap.
lag_threshold_ms = 10000
min_co_occurrences = 2
min_confidence = 0.5

[detection]
n_plus_one_min_occurrences = 5
EOF
}

wait_ready() {  # $1 = url
  for _ in $(seq 1 80); do
    curl -fsS "$1/api/status" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

SEND_FAILURES=0
emit() {  # $1 = url, $2 = service, $3 = table, $4 = event ms, $5 = trace num
  python3 "${EMIT}" --endpoint "$1" --service "$2" --shape n_plus_one \
    --table "$3" --at-ms "$4" --trace-num "$5" >> "${TMP_DIR}/send.log" 2>> "${TMP_DIR}/send.err" \
    || SEND_FAILURES=$((SEND_FAILURES + 1))
  sleep "${SEND_GAP_S}"
}

trace_hex() { printf '%032x' "$1"; }

# $1 = url, $2 = send C/D too (1/0). Event times sit five minutes in the
# past, inside the correlation window, far from the send times.
feed() {
  local anchor r t
  anchor=$(( $(date +%s) * 1000 - 300000 ))
  for r in $(seq 0 $((ROUNDS - 1))); do
    t=$((anchor + r * ROUND_GAP_MS))
    emit "$1" cet-a orders   "${t}"                    $((0xa00 + r))
    emit "$1" cet-b payments "$((t + AB_LAG_MS))"      $((0xb00 + r))
    if [ "$2" = "1" ]; then
      emit "$1" cet-d carts  "$((t + CD_LAG_MS))"      $((0xd00 + r))
      emit "$1" cet-c users  "${t}"                    $((0xc00 + r))
    fi
  done
  # One TTL plus the analysis tick, so the last batch reached the correlator.
  sleep 3
  [ "${SEND_FAILURES}" -eq 0 ] \
    || die "${SEND_FAILURES} send(s) failed, see ${TMP_DIR}/send.err; the legs would grade an incomplete corpus"
}

# $1 = correlations json, $2 = source service, $3 = target service, $4 = field
pair_field() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
path, src, dst, field = sys.argv[1:]
for c in json.load(open(path)):
    if c["source"]["service"] == src and c["target"]["service"] == dst:
        print(c.get(field, "absent"))
        sys.exit(0)
print("nopair")
PY
}

# --- under test --------------------------------------------------------------

step "Start the daemon under test and send both orders"
curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
  && die "something already serves ${DAEMON_URL}, leftover daemon from a previous run?"
write_config "${TMP_DIR}/daemon.toml" 127.0.0.1 "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}" 5
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
DAEMON_PID=$!
wait_ready "${DAEMON_URL}" || die "the daemon under test never became ready: $(tail -3 "${TMP_DIR}/daemon.log")"
feed "${DAEMON_URL}" 1
curl -fsS "${DAEMON_URL}/api/correlations" -o "${TMP_DIR}/correlations.json" \
  || die "GET /api/correlations failed"
ok "$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "${TMP_DIR}/correlations.json") pairs"

step "1. Lag is the gap between the two findings' own timestamps"
AB_LAG="$(pair_field "${TMP_DIR}/correlations.json" cet-a cet-b median_lag_ms)"
CD_LAG="$(pair_field "${TMP_DIR}/correlations.json" cet-c cet-d median_lag_ms)"
if [ "${AB_LAG}" = "${AB_LAG_MS}.0" ] || [ "${AB_LAG}" = "${AB_LAG_MS}" ]; then
  pass "1.ab" "A -> B median_lag_ms ${AB_LAG}"
else
  fail "1.ab" "A -> B median_lag_ms ${AB_LAG}, expected ${AB_LAG_MS}"
fi
if [ "${CD_LAG}" = "${CD_LAG_MS}.0" ] || [ "${CD_LAG}" = "${CD_LAG_MS}" ]; then
  pass "1.cd" "C -> D median_lag_ms ${CD_LAG}"
else
  fail "1.cd" "C -> D median_lag_ms ${CD_LAG}, expected ${CD_LAG_MS}"
fi

step "2. The earlier event is the source, whatever arrived first"
DC="$(pair_field "${TMP_DIR}/correlations.json" cet-d cet-c co_occurrence_count)"
CD_COUNT="$(pair_field "${TMP_DIR}/correlations.json" cet-c cet-d co_occurrence_count)"
if [ "${DC}" = "nopair" ] && [ "${CD_COUNT}" = "${ROUNDS}" ]; then
  pass "2.order" "C -> D counted ${CD_COUNT} times, no D -> C pair although D arrived first"
else
  fail "2.order" "C -> D count ${CD_COUNT}, D -> C ${DC}; expected ${ROUNDS} and nopair"
fi

step "3. Both sides name a trace Explain can open"
LAST=$((ROUNDS - 1))
SRC_TRACE="$(pair_field "${TMP_DIR}/correlations.json" cet-a cet-b source_sample_trace_id)"
DST_TRACE="$(pair_field "${TMP_DIR}/correlations.json" cet-a cet-b sample_trace_id)"
if [ "${SRC_TRACE}" = "$(trace_hex $((0xa00 + LAST)))" ] && [ "${DST_TRACE}" = "$(trace_hex $((0xb00 + LAST)))" ]; then
  pass "3.ids" "source_sample_trace_id ${SRC_TRACE}, sample_trace_id ${DST_TRACE}"
else
  fail "3.ids" "source_sample_trace_id ${SRC_TRACE}, sample_trace_id ${DST_TRACE}; expected the last round's A and B traces"
fi
for t in "${SRC_TRACE}" "${DST_TRACE}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${DAEMON_URL}/api/explain/${t}")"
  if [ "${code}" = "200" ]; then
    pass "3.explain" "/api/explain/${t} 200"
  else
    fail "3.explain" "/api/explain/${t} answered ${code}"
  fi
done

kill "${DAEMON_PID}" 2>/dev/null
wait "${DAEMON_PID}" 2>/dev/null
DAEMON_PID=""

# --- baseline ----------------------------------------------------------------

step "4. Counter-proof on ${BASELINE_IMAGE}"
write_config "${TMP_DIR}/baseline.toml" 0.0.0.0 14318 14317 5
docker rm -f "${BASELINE_NAME}" >/dev/null 2>&1
docker run -d --name "${BASELINE_NAME}" -p "${BASELINE_HTTP_PORT}:14318" \
  -v "${TMP_DIR}/baseline.toml:/etc/perf-sentinel/config.toml:ro" \
  "${BASELINE_IMAGE}" watch --config /etc/perf-sentinel/config.toml >/dev/null \
  || die "baseline container failed to start on ${BASELINE_IMAGE}"
wait_ready "${BASELINE_URL}" || die "baseline never became ready: $(docker logs "${BASELINE_NAME}" 2>&1 | tail -3)"
feed "${BASELINE_URL}" 0
curl -fsS "${BASELINE_URL}/api/correlations" -o "${TMP_DIR}/baseline-correlations.json" \
  || die "GET baseline /api/correlations failed"
BASE_LAG="$(pair_field "${TMP_DIR}/baseline-correlations.json" cet-a cet-b median_lag_ms)"
if [ "${BASE_LAG}" != "${AB_LAG_MS}.0" ] && [ "${BASE_LAG}" != "${AB_LAG_MS}" ]; then
  pass "4.counter-proof" "baseline A -> B lag ${BASE_LAG}, the tick gap rather than the event gap"
else
  fail "4.counter-proof" "baseline already reports ${BASE_LAG} ms, so leg 1 proves nothing about this build"
fi
docker rm -f "${BASELINE_NAME}" >/dev/null 2>&1

# --- validation --------------------------------------------------------------

step "5. window_minutes = 0 is refused at config load"
write_config "${TMP_DIR}/zero.toml" 127.0.0.1 "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}" 0
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/zero.toml" > "${TMP_DIR}/zero.log" 2>&1 &
ZPID=$!
sleep 3
if kill -0 "${ZPID}" 2>/dev/null; then
  kill "${ZPID}" 2>/dev/null
  fail "5.validation" "the daemon started with window_minutes = 0"
elif grep -q "window_minutes" "${TMP_DIR}/zero.log"; then
  pass "5.validation" "$(grep -m1 window_minutes "${TMP_DIR}/zero.log")"
else
  fail "5.validation" "the daemon exited without naming window_minutes: $(tail -1 "${TMP_DIR}/zero.log")"
fi

# --- verdict -----------------------------------------------------------------

VERDICT=PASS
[ "${FAILURES}" -eq 0 ] || VERDICT=FAIL
{
  echo "# ${SCENARIO}"
  echo
  echo "- Under test: ${VERSION} (${PRODUCT_COMMIT})"
  echo "- Baseline: ${BASELINE_IMAGE}"
  echo
  echo "| Leg | Result | Detail |"
  echo "| --- | --- | --- |"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r leg res detail <<< "${r}"
    echo "| ${leg} | ${res} | ${detail} |"
  done
  echo
  echo "Verdict: ${VERDICT}"
} > "${REPORT}"
cat "${REPORT}"
[ "${VERDICT}" = "PASS" ] && color_green "${SCENARIO}: PASS" || { color_red "${SCENARIO}: FAIL"; exit 1; }
