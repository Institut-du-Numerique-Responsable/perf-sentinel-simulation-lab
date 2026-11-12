#!/usr/bin/env bash
# limit-trace-shapes: adversarial trace shapes against the committed daemon,
# at low rate through the port-forward. One trait per sub-test:
#   (a) max_events  : one trace far above max_events_per_trace (ring buffer
#                     drops oldest spans SILENTLY -- documented as a feedback
#                     item, the drop has no counter today)
#   (b) deep_chain  : 400-deep parent chain (OTLP code-attr walk caps at 8,
#                     explain tree depth guard at 256)
#   (c) wide_fanout : 1200 sibling children under one root
#   (d) dup_trace_ids: identical trace ids re-emitted after the TTL expired
#                     (documented double-count semantics)
#   (e) huge_sql    : db.statement past the 64 KiB target cap
# Global asserts: zero pod restarts, daemon reachable throughout, RSS bounded.
# /api/export/report stays parseable.
set -euo pipefail

SCENARIO="limit-trace-shapes"
OBS_NS="observability"
DEPLOY="perf-sentinel-daemon"
DAEMON_SELECTOR="app.kubernetes.io/name=perf-sentinel-daemon"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TRACEGEN="${REPO_ROOT}/tools/tracegen/tracegen.py"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
ENDPOINT="http://localhost:${DAEMON_LOCAL_PORT}"
# DUP_GAP_S is not defaulted here: it comes from the daemon's own
# trace_ttl_ms below. This sub-test was written against a 5000 ms lab TTL
# and went on passing nothing once the lab moved to 30000 ms.

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

metric_val() {
  awk -v m="$1" '$1==m {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}
snapshot_metrics() { curl -fsS "${ENDPOINT}/metrics" > "${TMP_DIR}/metrics.txt"; }
daemon_restarts() {
  kubectl -n "${OBS_NS}" get pod -l "${DAEMON_SELECTOR}" \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0
}

# =============================================================================
step "Preflight: fresh daemon, 0.8.7 span counters present, host protobuf deps"
# The RSS envelope below is absolute, so it only means anything on a daemon
# that starts cold. The three sibling limit-* scenarios roll it for the same
# reason; this one inherited whatever the run before it left behind, and read
# 229 MiB against its own 200 MiB bound before sending a single span.
kubectl -n "${OBS_NS}" rollout restart deploy/"${DEPLOY}" >/dev/null
kubectl -n "${OBS_NS}" rollout status deploy/"${DEPLOY}" --timeout=180s >/dev/null \
  || die "daemon rollout failed"
pkill -f "port-forward.*${DEPLOY}" 2>/dev/null || true
"${REPO_ROOT}/scripts/port-forward.sh" start >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  curl -fsS --max-time 3 "${ENDPOINT}/api/status" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "${ENDPOINT}/api/status" >/dev/null \
  || die "daemon unreachable on ${ENDPOINT} after the rollout"
snapshot_metrics
grep -q "^# TYPE perf_sentinel_otlp_spans_received_total " "${TMP_DIR}/metrics.txt" \
  || die "perf_sentinel_otlp_spans_received_total absent (daemon is not 0.8.7? run scripts/seed-daemon-local.sh)"
python3 -c "import opentelemetry.proto" 2>/dev/null \
  || { skip "host python lacks opentelemetry-proto (pip install opentelemetry-proto); scenario skipped"; exit 0; }
# Every wait below is derived from this: a trace goes stale at the TTL and
# the sweep that analyses it runs on a ticker at half of it, so nothing this
# scenario sends can produce a finding before TTL + one tick.
TTL_S="$(curl -fsS "${ENDPOINT}/api/config" 2>/dev/null \
  | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["trace_ttl_ms"])//1000)' 2>/dev/null || echo "")"
[ -n "${TTL_S}" ] || die "cannot read trace_ttl_ms from ${ENDPOINT}/api/config (is [daemon] api_enabled = true?)"
ANALYSIS_WAIT_S=$(( TTL_S + TTL_S / 2 + 5 ))
RESTARTS_BEFORE="$(daemon_restarts)"
RSS_BEFORE="$(metric_val process_resident_memory_bytes)"
RECEIVED_BEFORE="$(metric_val perf_sentinel_otlp_spans_received_total)"
ok "daemon up, restarts=${RESTARTS_BEFORE}, rss=$(( RSS_BEFORE / 1048576 )) MiB"

run_shape() {
  local shape="$1"; shift
  python3 "${TRACEGEN}" --protocol http-pb --endpoint "${ENDPOINT}" \
    --shape "${shape}" --service-prefix "shape-${shape//_/-}" "$@" 2>"${TMP_DIR}/${shape}.err" | tail -1 \
    || die "tracegen ${shape} failed: $(tail -2 "${TMP_DIR}/${shape}.err")"
}

# =============================================================================
step "Sub-test a: one trace with 1500 spans (max_events_per_trace cap, silent ring drop)"
OUT="$(run_shape max_events --traces 3 --events-per-trace 1500)"
sleep 8  # let the TTL evict and the worker analyze
curl -fsS "${ENDPOINT}/api/export/report" > "${TMP_DIR}/report-a.json" || die "export/report unreachable after max_events"
python3 -c "import json;json.load(open('${TMP_DIR}/report-a.json'))" || die "export/report not parseable after max_events"
RESULT_max_events="sent $(echo "${OUT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["spans"])') spans, daemon stable (drop is unmetered: feedback item)"
ok "${RESULT_max_events}"

# =============================================================================
step "Sub-test b: 400-deep parent chain"
START_S="$(date +%s)"
OUT="$(run_shape deep_chain --traces 5 --chain-depth 400)"
WALL=$(( $(date +%s) - START_S ))
[ "${WALL}" -le 30 ] || die "deep_chain ingestion took ${WALL}s (latency cliff)"
SENT_SPANS="$(echo "${OUT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["spans"])')"
sleep 3
snapshot_metrics
RECEIVED_NOW="$(metric_val perf_sentinel_otlp_spans_received_total)"
[ $(( RECEIVED_NOW - RECEIVED_BEFORE )) -ge "${SENT_SPANS}" ] \
  || die "received delta $(( RECEIVED_NOW - RECEIVED_BEFORE )) < sent ${SENT_SPANS} for deep chains"
RESULT_deep_chain="${SENT_SPANS} spans in ${WALL}s, all received"
ok "${RESULT_deep_chain}"

# =============================================================================
step "Sub-test c: 1200-sibling fanout (finding expected)"
OUT="$(run_shape wide_fanout --traces 3 --fanout-width 1200)"
sleep "${ANALYSIS_WAIT_S}"
FANOUT_FOUND="$(curl -fsS "${ENDPOINT}/api/findings?type=excessive_fanout&limit=5" \
  | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
[ "${FANOUT_FOUND}" -ge 1 ] || die "no excessive_fanout finding after 1200-sibling traces"
RESULT_wide_fanout="excessive_fanout findings: ${FANOUT_FOUND}"
ok "${RESULT_wide_fanout}"

# =============================================================================
# The sweep runs on a ticker at trace_ttl_ms / 2, so a trace that goes
# stale between two ticks survives until the next one, and a re-emission
# landing in that gap is absorbed into it rather than opening a new
# trace. The deadline that matters is therefore TTL plus one tick, not
# TTL: measured on an isolated daemon, a 33s gap against a 30s TTL
# merged both generations into 20 traces analysed once.
DUP_GAP_S="${DUP_GAP_S:-$(( TTL_S + TTL_S / 2 + 5 ))}"
DUP_SETTLE_S=$(( TTL_S + TTL_S / 2 + 10 ))
step "Sub-test d: identical trace ids re-emitted after the ${TTL_S}s TTL (gap ${DUP_GAP_S}s)"
snapshot_metrics
TRACES_BEFORE="$(metric_val perf_sentinel_traces_analyzed_total)"
OUT="$(run_shape dup_trace_ids --traces 200 --dup-gap-s "${DUP_GAP_S}" --seed 31)"
sleep "${DUP_SETTLE_S}"
snapshot_metrics
TRACES_AFTER="$(metric_val perf_sentinel_traces_analyzed_total)"
D_TRACES=$(( TRACES_AFTER - TRACES_BEFORE ))
# Both generations must be analyzed: the second emission lands after the
# first was TTL-evicted, so the daemon counts ~2x200 (double-count by design,
# documented in LIMITATIONS).
[ "${D_TRACES}" -ge 300 ] || die "expected ~400 analyzed traces across both generations, got ${D_TRACES}"
RESULT_dup_trace_ids="analyzed ${D_TRACES} traces across two generations of 200 ids (double-count semantics)"
ok "${RESULT_dup_trace_ids}"

# =============================================================================
step "Sub-test e: 70 KB SQL statement (target cap is 64 KiB)"
snapshot_metrics
EVENTS_BEFORE="$(metric_val perf_sentinel_events_processed_total)"
OUT="$(run_shape huge_sql --traces 10 --sql-bytes 70000)"
# events_processed_total moves when a trace leaves the window (0.45.0), not at intake.
sleep "${ANALYSIS_WAIT_S}"
snapshot_metrics
EVENTS_AFTER="$(metric_val perf_sentinel_events_processed_total)"
[ $(( EVENTS_AFTER - EVENTS_BEFORE )) -ge 10 ] || die "huge-SQL events did not flow through (truncation broken?)"
REPORT_SIZE="$(curl -fsS "${ENDPOINT}/api/export/report" | wc -c | tr -d ' ')"
[ "${REPORT_SIZE}" -le $((10 * 1048576)) ] || die "export/report ballooned to ${REPORT_SIZE} bytes after huge SQL"
RESULT_huge_sql="events flowed, export/report ${REPORT_SIZE} bytes"
ok "${RESULT_huge_sql}"

# =============================================================================
step "Global asserts: restarts and RSS envelope"
RESTARTS_AFTER="$(daemon_restarts)"
[ "${RESTARTS_AFTER}" = "${RESTARTS_BEFORE}" ] || die "daemon restarted during shapes (${RESTARTS_BEFORE} -> ${RESTARTS_AFTER})"
snapshot_metrics
RSS_AFTER="$(metric_val process_resident_memory_bytes)"
# Absolute bound, not relative-to-start: the daemon usually starts cold
# here (fresh rollout), and the warm working set (findings store, window
# buffers, prometheus series, allocator retention) legitimately grows
# tens of MiB. The envelope that matters is the pod limit (256Mi).
RSS_LIMIT_BYTES="${RSS_LIMIT_BYTES:-209715200}"  # 200 MiB
[ "${RSS_AFTER}" -le "${RSS_LIMIT_BYTES}" ] \
  || die "RSS after the shapes is $(( RSS_AFTER/1048576 )) MiB (> $(( RSS_LIMIT_BYTES/1048576 )) MiB)"
ok "restarts=${RESTARTS_AFTER}, rss $(( RSS_BEFORE/1048576 )) -> $(( RSS_AFTER/1048576 )) MiB"

verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "| shape | result |"
  echo "|---|---|"
  for shape in max_events deep_chain wide_fanout dup_trace_ids huge_sql; do
    echo "| ${shape} | $(eval "echo \"\${RESULT_${shape}}\"") |"
  done
  echo "| restarts | ${RESTARTS_BEFORE} -> ${RESTARTS_AFTER} |"
  echo "| rss | $(( RSS_BEFORE/1048576 )) -> $(( RSS_AFTER/1048576 )) MiB |"
  echo ""
  echo "Feedback items: the per-trace ring-buffer drop above max_events_per_trace"
  echo "is unmetered (no counter), and duplicate trace ids across the TTL are"
  echo "double-counted by design."
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
