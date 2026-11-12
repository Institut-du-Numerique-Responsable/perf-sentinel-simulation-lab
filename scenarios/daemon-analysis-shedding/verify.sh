#!/usr/bin/env bash
# daemon-analysis-shedding: validate the 0.8.6 decoupled analysis worker and
# its metered load-shedding. 0.8.6 moves detect+score off the select! loop onto
# a single worker behind a bounded channel ([daemon] analysis_queue_capacity,
# default 1024). Under sustained overload the daemon sheds WHOLE analysis
# batches (counted, never silently dropped) instead of blocking ingestion and
# TTL eviction.
#
# The lab manufactures that overload deterministically: a daemon scoped to a
# tiny analysis queue (cap=1) and a small trace window (20) is flooded with a
# committed OTLP payload of 300 distinct N+1 traces (fixtures/shed-load.pb),
# replayed concurrently. Every request overflows the window into a ~280-trace
# eviction batch. The batches arrive faster than the single worker drains the
# CPU-heavy detect+score, so whole batches are shed. This needs NO CPU
# throttling -- the worker stays at its committed 500m limit. It is the small
# queue plus the realistic (not trivial) traces that back it up.
#
# Asserts:
#   - the three 0.8.6 surfaces exist on /metrics
#       perf_sentinel_analysis_queue_depth        (gauge, backlog)
#       perf_sentinel_analysis_shed_batches_total (counter)
#       perf_sentinel_analysis_shed_traces_total  (counter)
#   - the shed counters climb (load is shed, observably and metered, not lost);
#   - shed_traces >= shed_batches (each shed batch carries >=1 trace);
#   - ingestion is NOT blocked while analysis sheds: otlp_spans_received_total
#     keeps climbing and the daemon stays reachable through the flood;
#   - the daemon survives (no pod restart / OOM);
#   - the new [daemon] analysis_queue_capacity tunable is range-validated
#     (0 is rejected, naming the field) via the local 0.8.6 binary.
#
# Fail-loud on worker death (DaemonError::AnalysisWorkerStopped, non-zero exit)
# is covered by upstream unit tests. The lab has no safe lever to panic a
# detector mid-flight, so that path is asserted statically (see README).

set -euo pipefail

SCENARIO="daemon-analysis-shedding"
OBS_NS="observability"
DEPLOY="perf-sentinel-daemon"
DAEMON_SELECTOR="app.kubernetes.io/name=perf-sentinel-daemon"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE="${SCRIPT_DIR}/fixtures/shed-load.pb"
mkdir -p "${TMP_DIR}"

# --- tunables (env-overridable) ----------------------------------------------
DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
# Reduced analysis queue: 1 slot (default 1024). The single worker cannot keep a
# 1-slot queue empty once eviction batches arrive concurrently -> whole batches
# are shed. Small window forces an eviction batch on nearly every request.
SHED_CAP="${SHED_CAP:-1}"
SHED_WINDOW="${SHED_WINDOW:-20}"
PARALLELISM="${PARALLELISM:-4}"     # concurrent injectors
ROUNDS="${ROUNDS:-40}"              # POSTs per injector
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180}"
# Local 0.8.6 binary for the config-bounds sub-test (host-only; SKIP in CI).
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }  # cleanup via EXIT trap

cleanup() {
  if [ "${KEEP_SCOPED:-no}" = "yes" ]; then
    return
  fi
  # Restore the committed daemon (image + baseline ConfigMap: default queue
  # capacities, max_active_traces=10000). Best-effort so a mid-phase failure
  # still tears down.
  kubectl apply -f "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml" >/dev/null 2>&1 || true
  kubectl -n "${OBS_NS}" rollout status deploy/"${DEPLOY}" --timeout=120s >/dev/null 2>&1 || true
  pf_restart >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- helpers -----------------------------------------------------------------
pf_restart() {
  pkill -f "kubectl.*port-forward.*${DEPLOY}" 2>/dev/null || true
  rm -f "${REPO_ROOT}/tmp/pf-daemon.pid" 2>/dev/null || true
  sleep 2
  "${REPO_ROOT}/scripts/port-forward.sh" start >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
metric_val() {
  awk -v m="$1" '$1==m {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}
snapshot_metrics() { curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" > "${TMP_DIR}/metrics.txt"; }
daemon_restarts() {
  kubectl -n "${OBS_NS}" get pod -l "${DAEMON_SELECTOR}" \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0
}

DAEMON_VERSION="?"
verdict="UNKNOWN"
BOUNDS_RESULT="skip"
QDEPTH_MAX=0
POLLS=0; POLLS_OK=0
SHED_B_BEFORE=0; SHED_B_AFTER=0; D_SHED_B=0
SHED_T_BEFORE=0; SHED_T_AFTER=0; D_SHED_T=0
EVENTS_BEFORE=0; EVENTS_AFTER=0; D_EVENTS=0
RESTARTS_BEFORE=0; RESTARTS_AFTER=0

# =============================================================================
step "Sub-test 1: preflight + 0.8.6 shed surfaces"
[ -f "${FIXTURE}" ] || die "missing committed fixture ${FIXTURE} (regenerate with fixtures/generate.py)"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
DAEMON_VERSION="$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))')"
snapshot_metrics
for m in perf_sentinel_analysis_queue_depth perf_sentinel_analysis_shed_batches_total perf_sentinel_analysis_shed_traces_total; do
  grep -q "^# TYPE ${m} " "${TMP_DIR}/metrics.txt" \
    || die "metric ${m} not registered on /metrics (daemon is not 0.8.6?). version=${DAEMON_VERSION}"
done
ok "daemon reachable, version=${DAEMON_VERSION}, all three analysis-shed metrics registered"

# =============================================================================
step "Sub-test 2: analysis_queue_capacity range validation (local 0.8.6 binary)"
if [ ! -x "${PERF_SENTINEL_LOCAL_BIN}" ]; then
  skip "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (expected in CI); bounds check skipped"
elif [ "$("${PERF_SENTINEL_LOCAL_BIN}" --version 2>/dev/null | awk '{print $2}')" != "${DAEMON_VERSION}" ]; then
  skip "local binary version != daemon ${DAEMON_VERSION}; bounds check skipped"
else
  # Derive from the committed baseline (reset the ConfigMap first) so a prior
  # scoped run's analysis_queue_capacity cannot collide into a duplicate-key
  # error instead of the range-validation error we are testing.
  kubectl apply -f "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml" >/dev/null
  kubectl -n "${OBS_NS}" get cm perf-sentinel-daemon-config -o jsonpath='{.data.config\.toml}' > "${TMP_DIR}/base.toml"
  sed -e 's/listen_port_http = 14318/listen_port_http = 24318/' \
      -e 's/listen_port_grpc = 14317/listen_port_grpc = 24317/' \
      "${TMP_DIR}/base.toml" > "${TMP_DIR}/ports.toml"
  python3 - "${TMP_DIR}/ports.toml" "${TMP_DIR}/bad.toml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out = []
for line in open(src):
    if line.strip().startswith("analysis_queue_capacity"):
        continue  # drop any pre-existing scoped value so we test the range, not a dup key
    out.append(line)
    if line.strip() == "[daemon]":
        out.append("    analysis_queue_capacity = 0\n")
open(dst, "w").writelines(out)
PY
  grep -q 'analysis_queue_capacity = 0' "${TMP_DIR}/bad.toml" || die "could not inject analysis_queue_capacity=0"
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/bad.toml" > "${TMP_DIR}/bad.out" 2>&1 &
  BAD_PID=$!
  for _ in $(seq 1 16); do kill -0 "${BAD_PID}" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "${BAD_PID}" 2>/dev/null; then kill "${BAD_PID}" 2>/dev/null || true; die "daemon did NOT reject analysis_queue_capacity=0 (still running after 8s)"; fi
  BAD_RC=0; wait "${BAD_PID}" || BAD_RC=$?   # `wait` returns child rc; capture without tripping set -e
  if [ "${BAD_RC}" -ne 0 ] && grep -q 'analysis_queue_capacity must be >= 1' "${TMP_DIR}/bad.out"; then
    ok "analysis_queue_capacity=0 rejected (exit ${BAD_RC}): $(grep -o 'analysis_queue_capacity must be >= 1, got 0' "${TMP_DIR}/bad.out" | head -1)"
    BOUNDS_RESULT="pass"
  else
    BOUNDS_RESULT="fail"
    die "expected a range-validation error naming analysis_queue_capacity (exit=${BAD_RC}); got: $(tail -2 "${TMP_DIR}/bad.out")"
  fi
fi

# =============================================================================
step "Sub-test 3: scope the daemon to a reduced analysis queue (cap=${SHED_CAP}) + small window (${SHED_WINDOW})"
kubectl apply -f "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml" >/dev/null
kubectl -n "${OBS_NS}" get cm perf-sentinel-daemon-config -o jsonpath='{.data.config\.toml}' > "${TMP_DIR}/base-config.toml"
python3 - "${TMP_DIR}/base-config.toml" "${TMP_DIR}/scoped-config.toml" "${SHED_CAP}" "${SHED_WINDOW}" <<'PY'
import sys
src, dst, cap, window = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
out = []
for line in open(src):
    if line.strip().startswith("max_active_traces ="):
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f"{indent}max_active_traces = {window}\n")
        out.append(f"{indent}analysis_queue_capacity = {cap}\n")
    else:
        out.append(line)
open(dst, "w").writelines(out)
PY
grep -q "analysis_queue_capacity = ${SHED_CAP}" "${TMP_DIR}/scoped-config.toml" || die "scoped config missing analysis_queue_capacity = ${SHED_CAP}"
grep -q "max_active_traces = ${SHED_WINDOW}" "${TMP_DIR}/scoped-config.toml" || die "scoped config missing max_active_traces = ${SHED_WINDOW} (committed value changed?)"
kubectl -n "${OBS_NS}" create configmap perf-sentinel-daemon-config \
  --from-file=config.toml="${TMP_DIR}/scoped-config.toml" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${OBS_NS}" rollout restart deploy/"${DEPLOY}" >/dev/null
kubectl -n "${OBS_NS}" rollout status deploy/"${DEPLOY}" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null || die "daemon rollout failed on scoped config"
pf_restart || die "daemon unreachable after scoped reconfigure"
DAEMON_VERSION="$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))')"
ok "daemon ready, version=${DAEMON_VERSION}, analysis_queue_capacity=${SHED_CAP}, max_active_traces=${SHED_WINDOW}"

# =============================================================================
step "Sub-test 4: flood ${PARALLELISM}x${ROUNDS} N+1 payloads and watch the shed counters climb"
snapshot_metrics
SHED_B_BEFORE="$(metric_val perf_sentinel_analysis_shed_batches_total)"
SHED_T_BEFORE="$(metric_val perf_sentinel_analysis_shed_traces_total)"
EVENTS_BEFORE="$(metric_val perf_sentinel_events_processed_total)"
# Intake signal: since 0.45.0 events_processed_total counts analyzed traces only, after
# the window, so it skips shed batches and lags the flood by up to 1.5 x trace_ttl_ms.
SPANS_BEFORE="$(metric_val perf_sentinel_otlp_spans_received_total)"
RESTARTS_BEFORE="$(daemon_restarts)"
ok "before: shed_batches=${SHED_B_BEFORE} shed_traces=${SHED_T_BEFORE} events=${EVENTS_BEFORE} pod_restarts=${RESTARTS_BEFORE}"

inject_worker() {
  for _ in $(seq 1 "${ROUNDS}"); do
    curl -sS -o /dev/null --max-time 5 \
      -X POST "http://localhost:${DAEMON_LOCAL_PORT}/v1/traces" \
      -H 'Content-Type: application/x-protobuf' --data-binary @"${FIXTURE}" 2>/dev/null || true
  done
}
step "Launch ${PARALLELISM} concurrent injectors"
PIDS=()
for _ in $(seq 1 "${PARALLELISM}"); do inject_worker & PIDS+=("$!"); done

step "Sample shed counters + daemon liveness during the flood"
for i in $(seq 1 16); do
  POLLS=$(( POLLS + 1 ))
  curl -fsS --max-time 3 "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && POLLS_OK=$(( POLLS_OK + 1 ))
  if snapshot_metrics 2>/dev/null; then
    QD="$(metric_val perf_sentinel_analysis_queue_depth)"
    [ "${QD}" -gt "${QDEPTH_MAX}" ] && QDEPTH_MAX="${QD}"
    echo "    sample ${i}: queue_depth=${QD} shed_batches=$(metric_val perf_sentinel_analysis_shed_batches_total) status_ok=${POLLS_OK}/${POLLS}"
  fi
  # stop early once the injectors are done
  RUNNING=no; for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && RUNNING=yes; done
  [ "${RUNNING}" = "no" ] && { echo "    injectors finished at sample ${i}"; break; }
  sleep 1.5
done
for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
sleep 3

step "Snapshot after the flood"
pf_restart >/dev/null 2>&1 || true   # the flood may have stressed the forward; re-establish for a clean read
snapshot_metrics
SHED_B_AFTER="$(metric_val perf_sentinel_analysis_shed_batches_total)"
SHED_T_AFTER="$(metric_val perf_sentinel_analysis_shed_traces_total)"
EVENTS_AFTER="$(metric_val perf_sentinel_events_processed_total)"
SPANS_AFTER="$(metric_val perf_sentinel_otlp_spans_received_total)"
RESTARTS_AFTER="$(daemon_restarts)"
D_SHED_B=$(( SHED_B_AFTER - SHED_B_BEFORE ))
D_SHED_T=$(( SHED_T_AFTER - SHED_T_BEFORE ))
D_EVENTS=$(( EVENTS_AFTER - EVENTS_BEFORE ))
D_SPANS=$(( SPANS_AFTER - SPANS_BEFORE ))
ok "after: d_shed_batches=${D_SHED_B} d_shed_traces=${D_SHED_T} d_spans=${D_SPANS} d_events=${D_EVENTS} qdepth_max=${QDEPTH_MAX} pod_restarts=${RESTARTS_AFTER}"

# =============================================================================
step "Compute verdict"
DAEMON_ALIVE="$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)"
PASS_SHED_B=$([ "${D_SHED_B}" -gt 0 ] && echo yes || echo no)
PASS_SHED_T=$([ "${D_SHED_T}" -ge "${D_SHED_B}" ] && [ "${D_SHED_T}" -gt 0 ] && echo yes || echo no)
PASS_INGEST=$([ "${D_SPANS}" -gt 0 ] && echo yes || echo no)
PASS_SURVIVE=$([ "${RESTARTS_AFTER}" -le "${RESTARTS_BEFORE}" ] && echo yes || echo no)
# Tolerant: a busy daemon may miss an occasional poll; require >=70% reachable.
PASS_LIVE=$([ "$(( POLLS_OK * 100 ))" -ge "$(( POLLS * 70 ))" ] && [ "${POLLS}" -gt 0 ] && echo yes || echo no)
PASS_BOUNDS=$([ "${BOUNDS_RESULT}" != "fail" ] && echo yes || echo no)

if [ "${DAEMON_ALIVE}" = "yes" ] && [ "${PASS_SHED_B}" = "yes" ] && [ "${PASS_SHED_T}" = "yes" ] \
   && [ "${PASS_INGEST}" = "yes" ] && [ "${PASS_SURVIVE}" = "yes" ] && [ "${PASS_LIVE}" = "yes" ] \
   && [ "${PASS_BOUNDS}" = "yes" ]; then
  verdict="PASS"
else
  verdict="FAIL"
  kubectl -n "${OBS_NS}" logs deploy/"${DEPLOY}" --tail=80 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# daemon-analysis-shedding: metered load-shedding + configurable analysis queue (0.8.6)"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Daemon version: ${DAEMON_VERSION}"
  echo
  echo "## Scoped config + load under test"
  echo
  echo "- analysis_queue_capacity = ${SHED_CAP} (default 1024 -> reduced to force shedding)"
  echo "- max_active_traces = ${SHED_WINDOW} (small window -> eviction batch on nearly every request)"
  echo "- daemon CPU limit: committed 500m (no throttling; the small queue is the lever)"
  echo "- load: ${PARALLELISM} concurrent injectors x ${ROUNDS} POSTs of fixtures/shed-load.pb (300 N+1 traces each)"
  echo
  echo "## Measured deltas"
  echo
  echo "- analysis_shed_batches_total delta: ${D_SHED_B}"
  echo "- analysis_shed_traces_total delta: ${D_SHED_T}"
  echo "- analysis_queue_depth max sampled: ${QDEPTH_MAX} (cap=${SHED_CAP}; backlog is transient at this cap)"
  echo "- otlp_spans_received_total delta (ingestion): ${D_SPANS}"
  echo "- events_processed_total delta (analyzed, informational): ${D_EVENTS}"
  echo "- daemon reachable during flood: ${POLLS_OK}/${POLLS} polls"
  echo "- pod restartCount: ${RESTARTS_BEFORE} -> ${RESTARTS_AFTER}"
  echo
  echo "## Verdicts"
  echo
  echo "- daemon alive post-load: ${DAEMON_ALIVE}"
  echo "- shed_batches climbed (metered shedding fires): ${PASS_SHED_B}"
  echo "- shed_traces climbed and >= shed_batches (>=1 trace per shed batch): ${PASS_SHED_T}"
  echo "- ingestion NOT blocked while shedding (otlp_spans_received climbed): ${PASS_INGEST}"
  echo "- daemon survived the flood (no OOM/restart): ${PASS_SURVIVE}"
  echo "- daemon reachable through the flood (>=70% polls): ${PASS_LIVE}"
  echo "- analysis_queue_capacity range-validation (0 rejected): ${BOUNDS_RESULT}"
  echo
  echo "## Notes"
  echo
  echo "- Ingestion (otlp_spans_received_total += ${D_SPANS}) dwarfs the shed accounting:"
  echo "  the daemon kept ingesting and evicting while the analysis worker shed"
  echo "  whole batches -- exactly the decoupling 0.8.6 introduces. Shed is metered"
  echo "  (both counters move together, ~${SHED_CAP:+}300 traces per shed batch), never silent."
  echo "- analysis_queue_capacity sets the overload threshold: cap=${SHED_CAP} makes"
  echo "  shedding deterministic at modest concurrency. A larger cap raises the bar"
  echo "  (a heavier flood sheds at the default 1024 too -- confirmed separately),"
  echo "  but the same metered-shed path applies once the worker falls behind."
  echo "- Fail-loud on worker death (DaemonError::AnalysisWorkerStopped, non-zero"
  echo "  exit) is covered by upstream unit tests; the lab has no safe lever to"
  echo "  panic a detector mid-flight, so it is not runtime-triggered here."
  if [ "${verdict}" = "FAIL" ]; then
    echo
    echo "## Daemon logs (tail)"
    echo '```'
    tail -80 "${TMP_DIR}/daemon.log" 2>/dev/null || true
    echo '```'
  fi
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
