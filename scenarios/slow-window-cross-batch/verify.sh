#!/usr/bin/env bash
# slow-window-cross-batch: the 0.23.0 daemon counts slow episodes of one
# template across analysis batches.
#
# validate-findings' slow k6 scenarios put three or more slow spans in every
# trace, so detection happens inside one batch and the spans it reports are
# excluded from the window: the cross-batch path never fires in the rest of
# the lab. Here each episode is ONE slow span in its own trace, 65 s apart in
# wall clock (an episode spans max(60 s, 1.5 x trace_ttl_ms)), so no batch
# ever holds `slow_query_min_occurrences` of them.
#
# Three daemons receive the same three episodes:
#   under test, slow_query_window_minutes = 15 (the default)
#   under test, slow_query_window_minutes = 0 (disabled)
#   the last published image, which has no window
#
#   1. The windowed daemon reports one slow_sql finding with 3 occurrences.
#   2. Its trace_id is the trace of the episode that fired it, and
#      /api/explain opens it.
#   3. perf_sentinel_slow_window_keys_refused_total is exposed.
#   4. The disabled window reports nothing.
#   5. Counter-proof: the baseline reports nothing. A leg that passes on both
#      builds proves nothing about the new one.
#   6. slow_query_window_minutes = 61 is refused at config load.
#
# Self-contained: local release binary, Docker, python3, curl. No cluster.
# About three minutes, two of them waiting between episodes.
set -uo pipefail

SCENARIO="slow-window-cross-batch"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
EMIT="${LAB_ROOT}/tools/tracegen/emit_at.py"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

# The A side of the comparison: the last release without
# slow_query_window_minutes, which 0.23.0 added. It stays below 0.23.0. Bumped
# to the release under test, leg 5 passes on both builds and proves nothing.
BASELINE_IMAGE="${BASELINE_IMAGE:-ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.22.2}"
BASELINE_NAME="swcb-baseline-$$"

ON_HTTP="${SWCB_ON_HTTP_PORT:-14868}"
ON_GRPC="${SWCB_ON_GRPC_PORT:-14867}"
OFF_HTTP="${SWCB_OFF_HTTP_PORT:-14878}"
OFF_GRPC="${SWCB_OFF_GRPC_PORT:-14877}"
BASE_HTTP="${SWCB_BASELINE_HTTP_PORT:-14888}"
ON_URL="http://127.0.0.1:${ON_HTTP}"
OFF_URL="http://127.0.0.1:${OFF_HTTP}"
BASE_URL="http://127.0.0.1:${BASE_HTTP}"

EPISODES=3
EPISODE_GAP_S=65
SERVICE="swcb-svc"
TRACE_BASE=$((0x5100))

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

ON_PID=""
OFF_PID=""
cleanup() {
  [ -n "${ON_PID}" ] && kill "${ON_PID}" 2>/dev/null
  [ -n "${OFF_PID}" ] && kill "${OFF_PID}" 2>/dev/null
  docker rm -f "${BASELINE_NAME}" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# --- prerequisites -----------------------------------------------------------

step "Prerequisites"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no release binary at ${PERF_SENTINEL_LOCAL_BIN}, run: cd ${PERF_SENTINEL_REPO_PATH} && cargo build --release --workspace"
command -v docker >/dev/null 2>&1 || die "docker is required: leg 5 compares against ${BASELINE_IMAGE}"
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

write_config() {  # $1 = file, $2 = listen address, $3 = http, $4 = grpc, $5 = window line or ""
  cat > "$1" <<EOF
[daemon]
listen_address = "$2"
listen_port_http = $3
listen_port_grpc = $4
api_enabled = true
# Every trace closes before the next send, one trace per batch.
trace_ttl_ms = 1000

[daemon.ack]
enabled = false

[detection]
slow_query_threshold_ms = 500
slow_query_min_occurrences = ${EPISODES}
$5
EOF
}

wait_ready() {  # $1 = url
  for _ in $(seq 1 80); do
    curl -fsS "$1/api/status" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

# $1 = url -> "count|occurrences|trace_id" of slow_sql findings for SERVICE
slow_findings() {
  curl -fsS "$1/api/findings?limit=100&type=slow_sql&service=${SERVICE}" -o "${TMP_DIR}/slow.json" \
    || { echo "error"; return; }
  python3 - "${TMP_DIR}/slow.json" <<'PY'
import json, sys
rows = [r.get("finding", r) for r in json.load(open(sys.argv[1]))]
first = rows[0] if rows else {}
print(f"{len(rows)}|{first.get('pattern', {}).get('occurrences', '')}|{first.get('trace_id', '')}")
PY
}

# --- start -------------------------------------------------------------------

step "Start three daemons: window 15, window 0, ${BASELINE_IMAGE}"
write_config "${TMP_DIR}/on.toml" 127.0.0.1 "${ON_HTTP}" "${ON_GRPC}" "slow_query_window_minutes = 15"
write_config "${TMP_DIR}/off.toml" 127.0.0.1 "${OFF_HTTP}" "${OFF_GRPC}" "slow_query_window_minutes = 0"
write_config "${TMP_DIR}/baseline.toml" 0.0.0.0 14318 14317 ""
for url in "${ON_URL}" "${OFF_URL}" "${BASE_URL}"; do
  curl -fsS "${url}/api/status" >/dev/null 2>&1 \
    && die "something already serves ${url}, leftover daemon from a previous run?"
done
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/on.toml" > "${TMP_DIR}/on.log" 2>&1 &
ON_PID=$!
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/off.toml" > "${TMP_DIR}/off.log" 2>&1 &
OFF_PID=$!
docker rm -f "${BASELINE_NAME}" >/dev/null 2>&1
docker run -d --name "${BASELINE_NAME}" -p "${BASE_HTTP}:14318" \
  -v "${TMP_DIR}/baseline.toml:/etc/perf-sentinel/config.toml:ro" \
  "${BASELINE_IMAGE}" watch --config /etc/perf-sentinel/config.toml >/dev/null \
  || die "baseline container failed to start on ${BASELINE_IMAGE}"
wait_ready "${ON_URL}" || die "window-15 daemon never became ready: $(tail -3 "${TMP_DIR}/on.log")"
wait_ready "${OFF_URL}" || die "window-0 daemon never became ready: $(tail -3 "${TMP_DIR}/off.log")"
wait_ready "${BASE_URL}" || die "baseline never became ready: $(docker logs "${BASELINE_NAME}" 2>&1 | tail -3)"

step "Send ${EPISODES} episodes, one slow span each, ${EPISODE_GAP_S} s apart"
for i in $(seq 0 $((EPISODES - 1))); do
  for url in "${ON_URL}" "${OFF_URL}" "${BASE_URL}"; do
    python3 "${EMIT}" --endpoint "${url}" --service "${SERVICE}" --shape slow_one \
      --table orders --trace-num $((TRACE_BASE + i)) >> "${TMP_DIR}/send.log" 2>> "${TMP_DIR}/send.err" \
      || die "send to ${url} failed, see ${TMP_DIR}/send.err"
  done
  ok "episode $((i + 1)) sent at $(date +%T)"
  if [ "${i}" -lt $((EPISODES - 1)) ]; then
    # After the first episode nothing may report yet: one slow span is below
    # every per-batch rule, and one episode is below the window's count.
    if [ "${i}" -eq 0 ]; then
      sleep 3
      EARLY="$(slow_findings "${ON_URL}" | cut -d'|' -f1)"
      [ "${EARLY}" = "0" ] || warn "window daemon already reports ${EARLY} slow finding(s) after one episode"
    fi
    sleep "${EPISODE_GAP_S}"
  fi
done
sleep 4

# --- legs --------------------------------------------------------------------

step "1-2. The windowed daemon reports the template, on a trace Explain opens"
IFS='|' read -r ON_COUNT ON_OCC ON_TRACE <<< "$(slow_findings "${ON_URL}")"
LAST_TRACE="$(printf '%032x' $((TRACE_BASE + EPISODES - 1)))"
if [ "${ON_COUNT}" = "1" ] && [ "${ON_OCC}" = "${EPISODES}" ]; then
  pass "1.finding" "one slow_sql finding with ${ON_OCC} occurrences"
else
  fail "1.finding" "expected one slow_sql finding with ${EPISODES} occurrences, got count=${ON_COUNT} occurrences=${ON_OCC}"
fi
if [ "${ON_TRACE}" = "${LAST_TRACE}" ]; then
  pass "2.trace" "trace_id ${ON_TRACE} is the episode that fired it"
else
  fail "2.trace" "trace_id ${ON_TRACE}, expected ${LAST_TRACE}"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' "${ON_URL}/api/explain/${ON_TRACE}")"
[ "${code}" = "200" ] && pass "2.explain" "/api/explain/${ON_TRACE} 200" \
  || fail "2.explain" "/api/explain/${ON_TRACE} answered ${code}"

step "3. The key-cap counter is exposed"
if curl -fsS "${ON_URL}/metrics" | grep -q '^perf_sentinel_slow_window_keys_refused_total 0'; then
  pass "3.metric" "perf_sentinel_slow_window_keys_refused_total 0"
else
  fail "3.metric" "perf_sentinel_slow_window_keys_refused_total missing or non-zero"
fi

step "4. A disabled window reports nothing"
OFF_COUNT="$(slow_findings "${OFF_URL}" | cut -d'|' -f1)"
[ "${OFF_COUNT}" = "0" ] && pass "4.disabled" "window 0: no slow finding" \
  || fail "4.disabled" "window 0 still reports ${OFF_COUNT} slow finding(s)"

step "5. Counter-proof on ${BASELINE_IMAGE}"
BASE_COUNT="$(slow_findings "${BASE_URL}" | cut -d'|' -f1)"
[ "${BASE_COUNT}" = "0" ] && pass "5.counter-proof" "baseline: no slow finding for the same episodes" \
  || fail "5.counter-proof" "baseline reports ${BASE_COUNT} slow finding(s), so leg 1 proves nothing about this build"

kill "${ON_PID}" "${OFF_PID}" 2>/dev/null
wait "${ON_PID}" "${OFF_PID}" 2>/dev/null
ON_PID=""
OFF_PID=""
docker rm -f "${BASELINE_NAME}" >/dev/null 2>&1

step "6. slow_query_window_minutes = 61 is refused at config load"
write_config "${TMP_DIR}/over.toml" 127.0.0.1 "${ON_HTTP}" "${ON_GRPC}" "slow_query_window_minutes = 61"
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/over.toml" > "${TMP_DIR}/over.log" 2>&1 &
ZPID=$!
sleep 3
if kill -0 "${ZPID}" 2>/dev/null; then
  kill "${ZPID}" 2>/dev/null
  fail "6.validation" "the daemon started with slow_query_window_minutes = 61"
elif grep -q "slow_query_window_minutes" "${TMP_DIR}/over.log"; then
  pass "6.validation" "$(grep -m1 slow_query_window_minutes "${TMP_DIR}/over.log")"
else
  fail "6.validation" "the daemon exited without naming the key: $(tail -1 "${TMP_DIR}/over.log")"
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
