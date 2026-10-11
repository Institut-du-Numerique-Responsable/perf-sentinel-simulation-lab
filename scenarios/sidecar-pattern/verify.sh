#!/usr/bin/env bash
# sidecar pattern: 1 perf-sentinel daemon co-located in the same
# pod as the application service. Traces flow over localhost:14318
# inside the pod, never leave the network namespace.

set -euo pipefail

SCENARIO="sidecar-pattern"
NS="b2-6-sidecar"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
MANIFESTS="$(cd "$(dirname "$0")" && pwd)/manifests.yaml"
# The co-located daemon runs the image under validation, resolved by
# scripts/resolve-image.sh: PERF_SENTINEL_IMAGE, then PERF_SENTINEL_VERSION, then
# the daemon manifest pin. The manifest carries its own frozen digest and used to
# be applied unmodified, so the gate reported a PASS for a version this scenario
# had never executed.
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

PF_DAEMON_PID=""
PF_ORDER_PID=""
cleanup() {
  for pid in "${PF_DAEMON_PID}" "${PF_ORDER_PID}"; do
    if [ -n "${pid}" ]; then kill "${pid}" 2>/dev/null || true; fi
  done
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

verdict="UNKNOWN"
EVENTS=0; TRACES=0; FINDINGS=0
POD_MEMORY="?"

step "Mirror order-service-db secret to ${NS}"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n shop get secret order-service-db -o yaml \
  | sed -e "s/namespace: shop/namespace: ${NS}/" \
        -e '/resourceVersion:/d' -e '/uid:/d' -e '/creationTimestamp:/d' \
  | kubectl apply -f - >/dev/null
ok "secret order-service-db mirrored from shop"

step "Apply manifests"
# Rendered to a file rather than piped, so the rewrite can be asserted. A sed that
# matches nothing would silently run the digest frozen in manifests.yaml, which is
# the failure this resolution exists to prevent.
sed -e "s#image: ghcr.io/institut-du-numerique-responsable/perf-sentinel@sha256:[0-9a-f]*.*#image: ${IMAGE}#" "${MANIFESTS}" \
  > "${TMP_DIR}/manifests.rendered.yaml"
grep -qF "image: ${IMAGE}" "${TMP_DIR}/manifests.rendered.yaml" \
  || die "the perf-sentinel image rewrite matched nothing, the pod would run the digest frozen in manifests.yaml"
kubectl apply -f "${TMP_DIR}/manifests.rendered.yaml" > "${TMP_DIR}/apply.log" 2>&1
ok "manifests applied (sidecar daemon image ${IMAGE})"

step "Wait for the sidecar pod to become Ready (Spring Boot needs ~30s)"
kubectl -n "${NS}" rollout status deploy/order-service-sidecar --timeout=240s
sleep 20
ok "sidecar pod Ready"

step "Port-forward the sidecar daemon (host probe and report fetch)"
LOCAL_DAEMON_PORT=14618
kubectl -n "${NS}" port-forward svc/order-service-sidecar ${LOCAL_DAEMON_PORT}:14318 \
  > "${TMP_DIR}/pf-daemon.log" 2>&1 &
PF_DAEMON_PID=$!
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:${LOCAL_DAEMON_PORT}/api/status" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "http://localhost:${LOCAL_DAEMON_PORT}/api/status" >/dev/null 2>&1 \
  || die "sidecar daemon not reachable on localhost:${LOCAL_DAEMON_PORT}"
ok "sidecar daemon reachable"

step "Send a traffic burst from an in-cluster ephemeral pod"
# Spring Boot listens on the pod IP from the kubelet port-forward
# perspective, but the Service routes correctly cluster-internally. An
# ephemeral curl pod in the same namespace hits the Service over the
# cluster network and avoids the kubelet pf quirk.
kubectl -n "${NS}" run b2-6-traffic --image=curlimages/curl:8.10.1 --restart=Never --quiet \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"b2-6-traffic","image":"curlimages/curl:8.10.1","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["sh","-c","for i in $(seq 1 60); do curl -fsS -X POST http://order-service-sidecar.b2-6-sidecar.svc.cluster.local:8080/api/fault/n-plus-one-sql?items=15 >/dev/null 2>&1 || true; sleep 0.2; done"]}]}}' \
  -- sh -c "true" > /dev/null 2>&1 || true
# Wait for the traffic pod to finish (60 reqs x 0.2s sleep = ~12s).
for i in $(seq 1 60); do
  status=$(kubectl -n "${NS}" get pod b2-6-traffic -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
  if [ "${status}" = "Succeeded" ] || [ "${status}" = "Failed" ]; then break; fi
  sleep 1
done
kubectl -n "${NS}" delete pod b2-6-traffic --ignore-not-found --wait=false >/dev/null 2>&1 || true
ok "60 POST requests with items=15 sent in-cluster"

step "Wait for the OTel agent to flush and the daemon to process spans"
# The OTel Java agent's BatchSpanProcessor flushes every ~5s by default.
# With 60 requests x 16 spans each (1 server + 15 JDBC) = ~960 spans.
# Plus the daemon's TTL window must hold long enough for findings to fire.
sleep 30

step "Snapshot sidecar daemon report"
curl -fsS "http://localhost:${LOCAL_DAEMON_PORT}/api/export/report" > "${TMP_DIR}/sidecar-report.json"
EVENTS=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/sidecar-report.json')).get('analysis', {}).get('events_processed', 0))")
TRACES=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/sidecar-report.json')).get('analysis', {}).get('traces_analyzed', 0))")
FINDINGS=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/sidecar-report.json')).get('findings', [])))")
ok "events=${EVENTS} traces=${TRACES} findings=${FINDINGS}"

step "Measure pod memory footprint"
POD_NAME=$(kubectl -n "${NS}" get pod -l app.kubernetes.io/name=order-service-sidecar -o jsonpath='{.items[0].metadata.name}')
POD_MEMORY=$(kubectl -n "${NS}" top pod "${POD_NAME}" --no-headers 2>/dev/null | awk '{print $3}' || echo "metrics-server unavailable")
ok "pod memory: ${POD_MEMORY}"

if [ "${EVENTS}" -gt 0 ] && [ "${TRACES}" -gt 0 ]; then
  verdict="PASS"
else
  verdict="FAIL"
  kubectl -n "${NS}" logs deploy/order-service-sidecar -c perf-sentinel --tail=30 > "${TMP_DIR}/sidecar-daemon.log" 2>&1 || true
  kubectl -n "${NS}" logs deploy/order-service-sidecar -c order-service --tail=30 > "${TMP_DIR}/sidecar-order.log" 2>&1 || true
fi

step "Write report"
{
  echo "# sidecar pattern (1 daemon per service)"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Namespace: ${NS} (cleaned up after run unless KEEP_NAMESPACE=yes)"
  echo "Sidecar daemon image: ${IMAGE}"
  echo
  echo "Architecture:"
  echo "- 1 pod with 2 containers (order-service + perf-sentinel daemon)"
  echo "- Traces flow over localhost:14318 inside the pod, no cross-pod hop"
  echo "- Daemon binds 127.0.0.1:14318 to scope ingestion to the pod"
  echo
  echo "## Sidecar daemon snapshot"
  echo
  echo "- events_processed: ${EVENTS}"
  echo "- traces_analyzed: ${TRACES}"
  echo "- findings: ${FINDINGS}"
  echo "- pod memory footprint (cumulative for both containers): ${POD_MEMORY}"
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Sidecar daemon logs (tail)"
    echo
    echo '```'
    tail -30 "${TMP_DIR}/sidecar-daemon.log" 2>/dev/null || true
    echo '```'
    echo
    echo "## Order-service logs (tail)"
    echo
    echo '```'
    tail -30 "${TMP_DIR}/sidecar-order.log" 2>/dev/null || true
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
