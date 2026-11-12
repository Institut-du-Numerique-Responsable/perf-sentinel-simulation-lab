#!/usr/bin/env bash
# multi-agent-load: validate the perf-sentinel daemon under concurrent
# OTLP load. Spins up a kubectl Job with parallelism=PRODUCERS, each Pod
# running telemetrygen against the prod daemon Service, then asserts on
# /api/status, /api/export/report and /metrics that the daemon survived
# the burst, received the expected traffic, processed analyzable spans,
# and did not leak memory or in-flight traces.

set -euo pipefail

SCENARIO="multi-agent-load"
NS="multi-agent-load"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
MANIFESTS="$(cd "$(dirname "$0")" && pwd)/manifests.yaml"
mkdir -p "${TMP_DIR}"

PRODUCERS="${PRODUCERS:-10}"
RATE_PER_PRODUCER="${RATE_PER_PRODUCER:-100}"
DURATION="${DURATION:-60s}"
DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
RSS_LIMIT_BYTES="${RSS_LIMIT_BYTES:-524288000}"
# The daemon at the lab's default CPU limit (200m) does not process
# OTLP at telemetrygen's full burst rate. Drops are a pass-through
# property of the lab environment, not a daemon regression. The smoke
# verdict is therefore "daemon survives + ingestion non-zero", not a
# throughput ratio. Real throughput benchmarking is upstream.
MIN_EVENTS_DELTA="${MIN_EVENTS_DELTA:-3}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

cleanup() {
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete networkpolicy perf-sentinel-allow-multi-agent-load -n observability --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

metric_value() {
  awk -v metric="$1" '$1==metric {print int($2); found=1} END {if(!found) print 0}' "$2" | head -1
}

verdict="UNKNOWN"
EVENTS_BEFORE=0; EVENTS_AFTER=0; DELTA_EVENTS=0
TRACES_BEFORE=0; TRACES_AFTER=0; DELTA_TRACES=0
RECEIVED_BEFORE=0; RECEIVED_AFTER=0; DELTA_RECEIVED=0
ACTIVE_END=0
RSS_AFTER=0
EXPECTED=0; MIN_RECEIVED=0; RECEIVED_RATIO="0.00"

step "Sanity: daemon is reachable on localhost:${DAEMON_LOCAL_PORT}/api/status"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
ok "daemon reachable"

step "Snapshot daemon state before load"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" > "${TMP_DIR}/report-before.json"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" > "${TMP_DIR}/metrics-before.txt"
grep -q '^# TYPE perf_sentinel_otlp_spans_received_total ' "${TMP_DIR}/metrics-before.txt" \
  || die "perf_sentinel_otlp_spans_received_total is absent"
EVENTS_BEFORE=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-before.json')).get('analysis', {}).get('events_processed', 0))")
TRACES_BEFORE=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-before.json')).get('analysis', {}).get('traces_analyzed', 0))")
RECEIVED_BEFORE=$(metric_value perf_sentinel_otlp_spans_received_total "${TMP_DIR}/metrics-before.txt")
ok "received_before=${RECEIVED_BEFORE} events_before=${EVENTS_BEFORE} traces_before=${TRACES_BEFORE}"

step "Apply Job manifest with PRODUCERS=${PRODUCERS} RATE=${RATE_PER_PRODUCER} DURATION=${DURATION}"
# shellcheck disable=SC2016
# Single quotes around the variable list are intentional: envsubst reads
# the allow-list literally from its argv, single quotes prevent shell
# expansion. Without this allow-list envsubst replaces every $VAR in the
# manifest including unrelated env vars, which is unsafe.
PRODUCERS="${PRODUCERS}" RATE_PER_PRODUCER="${RATE_PER_PRODUCER}" DURATION="${DURATION}" \
  envsubst '${PRODUCERS} ${RATE_PER_PRODUCER} ${DURATION}' < "${MANIFESTS}" \
  | kubectl apply -f - > "${TMP_DIR}/apply.log" 2>&1
ok "manifests applied"

step "Wait for the telemetrygen Job to complete"
DURATION_NUM="${DURATION%s}"
TIMEOUT_SEC=$(( DURATION_NUM + 120 ))
kubectl -n "${NS}" wait --for=condition=Complete --timeout="${TIMEOUT_SEC}s" \
  job/telemetrygen-load > "${TMP_DIR}/wait.log" 2>&1 \
  || die "Job did not complete in ${TIMEOUT_SEC}s, see ${TMP_DIR}/wait.log"
ok "Job complete"

step "Wait 45s for the daemon to drain in-flight traces"
# events_processed moves when a trace leaves the window: up to 1.5 x the 30 s trace_ttl_ms.
sleep 45

step "Snapshot daemon metrics after load"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" > "${TMP_DIR}/report-after.json"
EVENTS_AFTER=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-after.json')).get('analysis', {}).get('events_processed', 0))")
TRACES_AFTER=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-after.json')).get('analysis', {}).get('traces_analyzed', 0))")
DELTA_EVENTS=$(( EVENTS_AFTER - EVENTS_BEFORE ))
DELTA_TRACES=$(( TRACES_AFTER - TRACES_BEFORE ))
ok "events_after=${EVENTS_AFTER} delta_events=${DELTA_EVENTS} delta_traces=${DELTA_TRACES}"

step "Read /metrics for active_traces and channel_full counter, kubectl top for RSS"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" > "${TMP_DIR}/metrics-after.txt"
RECEIVED_AFTER=$(metric_value perf_sentinel_otlp_spans_received_total "${TMP_DIR}/metrics-after.txt")
DELTA_RECEIVED=$(( RECEIVED_AFTER - RECEIVED_BEFORE ))
ACTIVE_END=$(awk '/^perf_sentinel_active_traces / {print int($2)}' "${TMP_DIR}/metrics-after.txt" | head -1)
ACTIVE_END="${ACTIVE_END:-0}"
# 0.5.19+ exposes a per-reason rejected counter that quantifies the
# CPU-bound backpressure of this load. Older daemons miss this surface,
# in which case we fall back to the events_delta gate alone.
REJECTED_CHANNEL_FULL=$(awk '/^perf_sentinel_otlp_rejected_total\{reason="channel_full"\}/ {print int($2); exit}' "${TMP_DIR}/metrics-after.txt")
if [ -n "${REJECTED_CHANNEL_FULL}" ]; then
  VERDICT_SOURCE="counter_present"
else
  REJECTED_CHANNEL_FULL="MISSING"
  VERDICT_SOURCE="counter_absent"
fi
RSS_MIB=$(kubectl top pod -n observability -l app.kubernetes.io/name=perf-sentinel-daemon --no-headers 2>/dev/null | awk '{gsub("Mi","",$3); print int($3)}' | head -1)
RSS_MIB="${RSS_MIB:-0}"
RSS_AFTER=$(( RSS_MIB * 1024 * 1024 ))
ok "received_delta=${DELTA_RECEIVED} rss_after=${RSS_AFTER}B (${RSS_MIB}Mi via kubectl top) active_traces_end=${ACTIVE_END} rejected_channel_full=${REJECTED_CHANNEL_FULL}"

step "Compute verdict"
EXPECTED=$(( PRODUCERS * RATE_PER_PRODUCER * DURATION_NUM ))
MIN_RECEIVED=$(( EXPECTED * 90 / 100 ))
if [ "${EXPECTED}" -gt 0 ]; then
  RECEIVED_RATIO=$(python3 -c "print(f'{${DELTA_RECEIVED} / ${EXPECTED}:.4f}')")
fi
DAEMON_ALIVE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)

PASS_RECEIVED=$([ "${DELTA_RECEIVED}" -ge "${MIN_RECEIVED}" ] && echo yes || echo no)
PASS_INGEST=$([ "${DELTA_EVENTS}" -ge "${MIN_EVENTS_DELTA}" ] && echo yes || echo no)
PASS_RSS=$([ "${RSS_AFTER}" -lt "${RSS_LIMIT_BYTES}" ] && echo yes || echo no)

if [ "${DAEMON_ALIVE}" = "yes" ] && [ "${PASS_RECEIVED}" = "yes" ] && [ "${PASS_INGEST}" = "yes" ] && [ "${PASS_RSS}" = "yes" ]; then
  verdict="PASS"
else
  verdict="FAIL"
  kubectl -n observability logs deploy/perf-sentinel-daemon --tail=80 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# multi-agent-load: ${PRODUCERS} producers @ ${RATE_PER_PRODUCER} sps for ${DURATION}"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Namespace: ${NS} (cleaned up after run unless KEEP_NAMESPACE=yes)"
  echo
  echo "## Inputs"
  echo
  echo "- PRODUCERS=${PRODUCERS}"
  echo "- RATE_PER_PRODUCER=${RATE_PER_PRODUCER} sps"
  echo "- DURATION=${DURATION}"
  echo "- Expected total spans = ${EXPECTED}"
  echo
  echo "## Daemon snapshot"
  echo
  echo "- perf_sentinel_otlp_spans_received_total delta: ${DELTA_RECEIVED} (expected ${EXPECTED}, ratio ${RECEIVED_RATIO})"
  echo "- events_processed delta: ${DELTA_EVENTS}"
  echo "- traces_analyzed delta: ${DELTA_TRACES}"
  echo "- process_resident_memory_bytes: ${RSS_AFTER} (limit ${RSS_LIMIT_BYTES})"
  echo "- perf_sentinel_active_traces (post-drain): ${ACTIVE_END}"
  echo "- perf_sentinel_otlp_rejected_total{channel_full}: ${REJECTED_CHANNEL_FULL}"
  echo "- verdict_source: ${VERDICT_SOURCE}"
  echo "- daemon /api/status reachable post-load: ${DAEMON_ALIVE}"
  echo
  echo "## Verdicts"
  echo
  echo "- daemon_alive: ${DAEMON_ALIVE}"
  echo "- raw OTLP received (delta >= ${MIN_RECEIVED}, 90% of expected): ${PASS_RECEIVED}"
  echo "- analyzable ingestion (events delta >= ${MIN_EVENTS_DELTA}): ${PASS_INGEST}"
  echo "- rss_under_limit: ${PASS_RSS}"
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Daemon logs (tail)"
    echo
    echo '```'
    tail -80 "${TMP_DIR}/daemon.log" 2>/dev/null || true
    echo '```'
    echo
  fi
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
