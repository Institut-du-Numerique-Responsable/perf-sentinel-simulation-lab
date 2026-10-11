#!/usr/bin/env bash
# otlp-compression-matrix: every transport x encoding combination an OTLP
# exporter can put on the wire, against the daemon under test.
#
# Why it exists: until 0.9.28 the daemon's gRPC listener never called
# accept_compressed, so tonic refused every gzipped export with a permanent
# Unimplemented and the Collector dropped each batch. The pod stayed Ready,
# /health answered, the counters stayed at zero, and the outage lived only in
# the Collector's logs. The lab missed it for months because its own collector
# exports over otlphttp (:14318) and its only gRPC producers (tracegen,
# telemetrygen) never compressed. This scenario is the regression test for
# that blind spot, and it covers HTTP as well so neither transport is traded
# for the other.
#
# The full leg matrix is the table in README.md.
#
# Legs A-H are self-contained: Docker only, no cluster, no local binary (the
# A/B needs a published image, not a build). Leg I overlays the real cluster
# collector onto :14317 and reverts on exit. It SKIPs cleanly with no cluster.
#
# Deflate over gRPC is unreachable from the Collector's exporter (gzip, snappy
# and zstd only), so legs F/G go through tracegen's native client instead.
set -uo pipefail

SCENARIO="otlp-compression-matrix"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# IMAGE = the version under validation (manifest pin, PERF_SENTINEL_VERSION or
# PERF_SENTINEL_IMAGE). BASELINE_IMAGE = the last release that carried the bug;
# without it a green run cannot tell "fixed" from "never exercised".
. "${LAB_ROOT}/scripts/resolve-image.sh"
BASELINE_IMAGE="${BASELINE_IMAGE:-ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.9.26}"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.155.0}"
TRACEGEN_IMAGE="${TRACEGEN_IMAGE:-lab-tracegen:1}"

NET="ocm-net"
DAEMON_NAME="ocm-daemon"
COLLECTOR_NAME="ocm-collector"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14418}"   # host-published, daemon listens on 14318/14317
COLLECTOR_HTTP_PORT="${COLLECTOR_HTTP_PORT:-14428}"
COLLECTOR_HEALTH_PORT="${COLLECTOR_HEALTH_PORT:-14438}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
TRACES="${TRACES:-40}"

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"
rm -f "${REPORT}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_yellow "    warn: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }
FAILURES=0
fail() { color_red "    FAIL: $2"; record "$1" "FAIL" "$2"; FAILURES=$((FAILURES + 1)); }

CLUSTER_OVERLAY_APPLIED=0
cleanup() {
  docker rm -f "${COLLECTOR_NAME}" "${DAEMON_NAME}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  if [ "${CLUSTER_OVERLAY_APPLIED}" -eq 1 ]; then
    color_yellow "==> reverting the cluster collector to the committed values"
    helm upgrade otel-collector open-telemetry/opentelemetry-collector \
      --version "$(otel_chart_version)" -n observability \
      -f "${LAB_ROOT}/helm/values/otel-collector.yaml" \
      > "${TMP_DIR}/helm-revert.log" 2>&1 \
      || color_red "REVERT FAILED, the cluster collector still exports over gRPC: $(tail -3 "${TMP_DIR}/helm-revert.log")"
  fi
}
trap cleanup EXIT

otel_chart_version() {
  local v
  v="$(helm -n observability get metadata otel-collector 2>/dev/null | awk '/^VERSION:/{print $2}')"
  [ -n "${v}" ] || { echo "cannot read the installed otel-collector chart version" >&2; return 1; }
  printf '%s' "${v}"
}

# --------------------------------------------------------------------------
step "0. Pre-flight"
command -v docker >/dev/null || die "docker not on PATH"
docker info >/dev/null 2>&1 || die "docker daemon not reachable"
command -v curl >/dev/null   || die "curl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"

# tracegen carries the grpcio client the Collector cannot replace (no deflate
# on its gRPC exporter). Build it here: seed-tracegen.sh also imports into
# k3d, which this scenario must not require.
if ! docker image inspect "${TRACEGEN_IMAGE}" >/dev/null 2>&1; then
  step "building ${TRACEGEN_IMAGE}"
  docker build -q -t "${TRACEGEN_IMAGE}" "${LAB_ROOT}/tools/tracegen" >/dev/null \
    || die "tracegen image build failed"
fi
docker pull -q "${COLLECTOR_IMAGE}" >/dev/null 2>&1 || warn "could not refresh ${COLLECTOR_IMAGE}, using the local copy"
docker pull -q "${BASELINE_IMAGE}"  >/dev/null 2>&1 || warn "could not refresh ${BASELINE_IMAGE}, using the local copy"
docker image inspect "${BASELINE_IMAGE}" >/dev/null 2>&1 || die "baseline image unavailable: ${BASELINE_IMAGE}"

docker network create "${NET}" >/dev/null 2>&1 || true
ok "under test: ${IMAGE}"
ok "baseline:   ${BASELINE_IMAGE}"

cat > "${TMP_DIR}/config.toml" <<EOF
[daemon]
listen_address = "0.0.0.0"
listen_port_http = 14318
listen_port_grpc = 14317
max_active_traces = 5000
trace_ttl_ms = 2000
api_enabled = true
environment = "staging"

[detection]
n_plus_one_min_occurrences = 5
EOF

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

start_daemon() {  # $1 = image
  docker rm -f "${DAEMON_NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${DAEMON_NAME}" --network "${NET}" \
    -p "${DAEMON_HTTP_PORT}:14318" \
    -v "${TMP_DIR}/config.toml:/etc/perf-sentinel/config.toml:ro" \
    "$1" watch --config /etc/perf-sentinel/config.toml >/dev/null \
    || die "daemon container failed to start on $1"
  for _ in $(seq 1 60); do
    curl -fsS "${DAEMON_URL}/health" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  die "daemon on $1 never became healthy: $(docker logs "${DAEMON_NAME}" 2>&1 | tail -5)"
}

start_collector() {  # $1 = otlp|otlphttp, $2 = compression codec or "default"
  local exporter="$1" codec="$2" endpoint line
  if [ "${exporter}" = "otlp" ]; then
    endpoint="${DAEMON_NAME}:14317"          # gRPC target: host:port, no scheme
  else
    endpoint="http://${DAEMON_NAME}:14318"
  fi
  if [ "${codec}" = "default" ]; then
    line="# compression: absent on purpose -> the OTel default, gzip"
  else
    line="compression: ${codec}"
  fi
  # '|' as the separator: the default-compression replacement is a YAML
  # comment, so it starts with '#'.
  sed -e "s|__EXPORTER__|${exporter}|g" \
      -e "s|__ENDPOINT__|${endpoint}|" \
      -e "s|__COMPRESSION__|${line}|" \
      "${SCRIPT_DIR}/collector-config.tmpl.yaml" > "${TMP_DIR}/collector.yaml"
  docker rm -f "${COLLECTOR_NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${COLLECTOR_NAME}" --network "${NET}" \
    -p "${COLLECTOR_HTTP_PORT}:4318" -p "${COLLECTOR_HEALTH_PORT}:13133" \
    -v "${TMP_DIR}/collector.yaml:/cfg/config.yaml:ro" \
    "${COLLECTOR_IMAGE}" --config=/cfg/config.yaml >/dev/null \
    || die "collector container failed to start"
  for _ in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:${COLLECTOR_HEALTH_PORT}/" 2>/dev/null && return 0
    docker ps --filter "name=${COLLECTOR_NAME}" --filter status=running -q | grep -q . \
      || die "collector exited: $(docker logs "${COLLECTOR_NAME}" 2>&1 | tail -10)"
    sleep 0.5
  done
  die "collector never became healthy: $(docker logs "${COLLECTOR_NAME}" 2>&1 | tail -10)"
}

metric() {  # $1 = metric name -> integer value (0 when absent), same shape as limit-multi-source
  curl -fsS --max-time 5 "${DAEMON_URL}/metrics" 2>/dev/null \
    | awk -v m="$1" '$1==m {print int($2); found=1} END {if(!found) print 0}' | head -1
}

findings_count() {  # $1 = optional finding_type filter; /api/findings is a bare
                    # array on some versions and {"findings": [...]} on others
  curl -fsS --max-time 5 "${DAEMON_URL}/api/findings" 2>/dev/null \
    | python3 -c '
import sys, json
want = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
items = d if isinstance(d, list) else d.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
# The daemon spells it "type" under a "finding" envelope. Keep the
# finding_type fallback so a rename upstream degrades to 0, not to a crash.
def t(it): return u(it).get("type", u(it).get("finding_type"))
print(sum(1 for it in items if not want or t(it) == want))' "${1:-}" 2>/dev/null || echo 0
}

send_via_collector() {
  docker run --rm --network "${NET}" "${TRACEGEN_IMAGE}" \
    --endpoint "http://${COLLECTOR_NAME}:4318" --protocol http-pb \
    --traces "${TRACES}" --tps "${TRACES}" --duration 1 --services 3 \
    --service-prefix "ocm" --mix "n_plus_one:100" \
    > "${TMP_DIR}/tracegen-last.json" 2>"${TMP_DIR}/tracegen-last.err"
}

send_direct() {  # $1 = http-pb|grpc, $2 = compression
  local port=14318
  [ "$1" = "grpc" ] && port=14317
  docker run --rm --network "${NET}" "${TRACEGEN_IMAGE}" \
    --endpoint "http://${DAEMON_NAME}:${port}" --protocol "$1" --compression "$2" \
    --traces "${TRACES}" --tps "${TRACES}" --duration 1 --services 3 \
    --service-prefix "ocm" --mix "n_plus_one:100" \
    > "${TMP_DIR}/tracegen-last.json" 2>"${TMP_DIR}/tracegen-last.err"
}

# Spans take the batch processor (1s) plus the daemon's 2s TTL before they are
# counted and analysed.
settle() { sleep 6; }

collector_refused() {  # 0 when the collector logged a permanent encoding refusal
  docker logs "${COLLECTOR_NAME}" 2>&1 | grep -i "unimplemented" >/dev/null
}

# --------------------------------------------------------------------------
step "A. gRPC, exporter default (gzip), image under test"
start_daemon "${IMAGE}"
start_collector "otlp" "default"
BEFORE="$(metric perf_sentinel_otlp_spans_received_total)"
send_via_collector || die "tracegen failed: $(tail -3 "${TMP_DIR}/tracegen-last.err")"
settle
AFTER="$(metric perf_sentinel_otlp_spans_received_total)"
DELTA=$((AFTER - BEFORE))
FINDINGS="$(findings_count)"
docker logs "${COLLECTOR_NAME}" > "${TMP_DIR}/A-collector.log" 2>&1
if [ "${DELTA}" -gt 0 ] && [ "${FINDINGS}" -gt 0 ] && ! collector_refused; then
  ok "gzipped gRPC ingested: +${DELTA} spans, ${FINDINGS} finding(s), no Unimplemented"
  record "A-grpc-gzip" "PASS" "+${DELTA} spans, ${FINDINGS} findings, collector log clean"
else
  fail "A-grpc-gzip" "delta=${DELTA} findings=${FINDINGS} refused=$(collector_refused && echo yes || echo no); log: $(grep -i -m1 unimplemented "${TMP_DIR}/A-collector.log" || echo none)"
fi

# --------------------------------------------------------------------------
step "B. same leg against ${BASELINE_IMAGE} (counter-proof)"
start_daemon "${BASELINE_IMAGE}"
start_collector "otlp" "default"
BEFORE="$(metric perf_sentinel_otlp_spans_received_total)"
send_via_collector || warn "tracegen reported an error (the collector still accepted the spans)"
settle
AFTER="$(metric perf_sentinel_otlp_spans_received_total)"
DELTA=$((AFTER - BEFORE))
docker logs "${COLLECTOR_NAME}" > "${TMP_DIR}/B-collector.log" 2>&1
BASELINE_MSG="$(grep -i -m1 "unimplemented" "${TMP_DIR}/B-collector.log" | tr -d '\r' | cut -c1-300)"
if [ "${DELTA}" -eq 0 ] && [ -n "${BASELINE_MSG}" ]; then
  ok "baseline drops every batch: +0 spans, collector logged Unimplemented"
  echo "        ${BASELINE_MSG}"
  record "B-baseline-refuses" "PASS" "0 spans ingested on ${BASELINE_IMAGE}, Unimplemented in the collector log"
else
  fail "B-baseline-refuses" "expected 0 spans + Unimplemented on the baseline, got delta=${DELTA} msg='${BASELINE_MSG:-none}' (is the A/B really running two different builds?)"
fi

# --------------------------------------------------------------------------
step "C-E. paths that already worked, image under test (non-regression)"
start_daemon "${IMAGE}"
for leg in "C:otlp:none:gRPC uncompressed" "D:otlphttp:default:HTTP gzip" "E:otlphttp:none:HTTP uncompressed"; do
  IFS=":" read -r tag exporter codec label <<< "${leg}"
  start_collector "${exporter}" "${codec}"
  BEFORE="$(metric perf_sentinel_otlp_spans_received_total)"
  send_via_collector || warn "${tag}: tracegen reported an error"
  settle
  AFTER="$(metric perf_sentinel_otlp_spans_received_total)"
  DELTA=$((AFTER - BEFORE))
  if [ "${DELTA}" -gt 0 ] && ! collector_refused; then
    ok "${tag} ${label}: +${DELTA} spans"
    record "${tag}-${exporter}-${codec}" "PASS" "${label}: +${DELTA} spans"
  else
    fail "${tag}-${exporter}-${codec}" "${label}: delta=${DELTA}, collector log: $(docker logs "${COLLECTOR_NAME}" 2>&1 | grep -i -m1 'error\|unimplemented' || echo none)"
  fi
done

# --------------------------------------------------------------------------
step "F/G. deflate, native client (new in 0.9.28)"
docker rm -f "${COLLECTOR_NAME}" >/dev/null 2>&1 || true
for leg in "F:http-pb:HTTP deflate" "G:grpc:gRPC deflate"; do
  IFS=":" read -r tag proto label <<< "${leg}"
  BEFORE="$(metric perf_sentinel_otlp_spans_received_total)"
  SEND_RC=0
  send_direct "${proto}" "deflate" || SEND_RC=$?
  settle
  AFTER="$(metric perf_sentinel_otlp_spans_received_total)"
  DELTA=$((AFTER - BEFORE))
  if [ "${DELTA}" -gt 0 ] && [ "${SEND_RC}" -eq 0 ]; then
    ok "${tag} ${label}: +${DELTA} spans"
    record "${tag}-deflate-${proto}" "PASS" "${label}: +${DELTA} spans"
  else
    fail "${tag}-deflate-${proto}" "${label}: delta=${DELTA} rc=${SEND_RC}, sender: $(tail -2 "${TMP_DIR}/tracegen-last.err" | tr '\n' ' ')"
  fi
done

step "F'. HTTP deflate against ${BASELINE_IMAGE} (counter-proof)"
start_daemon "${BASELINE_IMAGE}"
BEFORE="$(metric perf_sentinel_otlp_spans_received_total)"
SEND_RC=0
send_direct "http-pb" "deflate" || SEND_RC=$?
settle
AFTER="$(metric perf_sentinel_otlp_spans_received_total)"
DELTA=$((AFTER - BEFORE))
if [ "${DELTA}" -eq 0 ] && [ "${SEND_RC}" -ne 0 ]; then
  ok "baseline refuses HTTP deflate: +0 spans, sender errored"
  record "F2-baseline-deflate" "PASS" "0 spans on ${BASELINE_IMAGE}, sender rejected"
else
  fail "F2-baseline-deflate" "expected a refusal on the baseline, got delta=${DELTA} rc=${SEND_RC}"
fi

# --------------------------------------------------------------------------
step "H. unsupported codecs stay refused (zstd, snappy)"
start_daemon "${IMAGE}"
for codec in zstd snappy; do
  start_collector "otlp" "${codec}"
  BEFORE="$(metric perf_sentinel_otlp_spans_received_total)"
  send_via_collector || warn "H/${codec}: tracegen reported an error"
  settle
  AFTER="$(metric perf_sentinel_otlp_spans_received_total)"
  DELTA=$((AFTER - BEFORE))
  docker logs "${COLLECTOR_NAME}" > "${TMP_DIR}/H-${codec}-collector.log" 2>&1
  if [ "${DELTA}" -eq 0 ] && collector_refused; then
    ok "${codec}: refused with Unimplemented, 0 spans ingested (docs/INSTRUMENTATION.md holds)"
    record "H-${codec}-refused" "PASS" "0 spans, Unimplemented as documented"
  else
    fail "H-${codec}-refused" "expected a refusal, got delta=${DELTA} refused=$(collector_refused && echo yes || echo no)"
  fi
done
docker rm -f "${COLLECTOR_NAME}" "${DAEMON_NAME}" >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
step "I. cluster collector switched to gRPC (real topology)"
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl -n observability get deploy/perf-sentinel-daemon >/dev/null 2>&1; then
  warn "no cluster reachable, SKIP (legs A-H already cover the encodings)"
  record "I-cluster-grpc" "SKIP" "no cluster"
else
  ORDER_POD="$(kubectl -n shop get pod -l app.kubernetes.io/name=order-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -z "${ORDER_POD}" ]; then
    warn "order-service not deployed, SKIP (run make seed-services first)"
    record "I-cluster-grpc" "SKIP" "order-service absent"
  else
    # Arm the revert BEFORE the upgrade: a partial apply that then errors has
    # still mutated the shared collector, and only the trap puts it back.
    CLUSTER_OVERLAY_APPLIED=1
    helm upgrade otel-collector open-telemetry/opentelemetry-collector \
      --version "$(otel_chart_version)" -n observability \
      -f "${LAB_ROOT}/helm/values/otel-collector.yaml" \
      -f "${SCRIPT_DIR}/collector-overlay.yaml" > "${TMP_DIR}/helm.log" 2>&1 \
      || die "helm upgrade with the gRPC overlay failed: $(tail -3 "${TMP_DIR}/helm.log")"
    DS_NAME="$(kubectl -n observability get ds -o name | grep -m1 otel-collector)"
    kubectl -n observability rollout status "${DS_NAME}" --timeout=180s >/dev/null \
      || die "collector daemonset rollout did not converge"

    # Collector pods are not restarted by the overlay upgrade, so their logs
    # still carry any Unimplemented from an earlier run (a previous validation
    # against a pre-fix image, say). Count the delta, never the absolute.
    UNIMPL_BEFORE="$(kubectl -n observability logs -l app.kubernetes.io/name=opentelemetry-collector --tail=-1 2>/dev/null | grep -ci unimplemented || true)"
    kubectl -n shop port-forward "${ORDER_POD}" 18291:8080 > "${TMP_DIR}/pf-order.log" 2>&1 &
    PF_PID=$!
    kubectl -n observability port-forward svc/perf-sentinel-daemon 14498:14318 > "${TMP_DIR}/pf-daemon.log" 2>&1 &
    PF_DAEMON_PID=$!
    sleep 5
    # The cluster daemon becomes the measured one for the rest of the run.
    DAEMON_URL="http://127.0.0.1:14498"
    CL_BEFORE="$(metric perf_sentinel_otlp_spans_received_total)"
    for _ in $(seq 1 10); do
      curl -fsS -X POST "http://localhost:18291/api/fault/n-plus-one-sql?items=15" >/dev/null 2>&1 || true
      sleep 0.3
    done
    sleep 20   # batch timeout 5s + daemon TTL + analysis
    CL_AFTER="$(metric perf_sentinel_otlp_spans_received_total)"
    CL_FINDINGS="$(findings_count n_plus_one_sql)"
    UNIMPL_AFTER="$(kubectl -n observability logs -l app.kubernetes.io/name=opentelemetry-collector --tail=-1 2>/dev/null | grep -ci unimplemented || true)"
    COLLECTOR_ERR=$((UNIMPL_AFTER - UNIMPL_BEFORE))
    # `wait` after the kill, otherwise bash prints its own "Terminated" job
    # notice into the middle of the scenario output.
    kill "${PF_PID}" "${PF_DAEMON_PID}" 2>/dev/null || true
    wait "${PF_PID}" "${PF_DAEMON_PID}" 2>/dev/null || true
    CL_DELTA=$((CL_AFTER - CL_BEFORE))
    if [ "${CL_DELTA}" -gt 0 ] && [ "${CL_FINDINGS}" -gt 0 ] && [ "${COLLECTOR_ERR}" -eq 0 ]; then
      ok "cluster collector on gRPC+gzip: +${CL_DELTA} spans, ${CL_FINDINGS} n_plus_one_sql finding(s)"
      record "I-cluster-grpc" "PASS" "+${CL_DELTA} spans, ${CL_FINDINGS} findings through the real collector on :14317"
    else
      fail "I-cluster-grpc" "delta=${CL_DELTA} findings=${CL_FINDINGS} unimplemented_lines=${COLLECTOR_ERR}"
    fi
  fi
fi

# --------------------------------------------------------------------------
step "Summary"
VERDICT="PASS"; [ "${FAILURES}" -gt 0 ] && VERDICT="FAIL"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "Under test: \`${IMAGE}\`"
  echo "Baseline:   \`${BASELINE_IMAGE}\`"
  echo ""
  echo "| check | verdict | note |"
  echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
  echo ""
  echo "Verdict: **${VERDICT}**"
} > "${REPORT}"

if [ "${FAILURES}" -gt 0 ]; then
  color_red "FAIL (${FAILURES}) — report at ${REPORT}"
  exit 1
fi
color_green "PASS — report at ${REPORT}"
