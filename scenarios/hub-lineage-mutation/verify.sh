#!/usr/bin/env bash
# When a query's shape changes, the finding is a new one. Its history is not.
#
# The signature is derived from the normalized SQL template, so adding a
# predicate mints a brand-new signature. Treated naively that reads as "the old
# problem is gone, a new one appeared" and the age of the real problem resets to
# zero. The Hub links the pair instead: same service, same finding type, same
# endpoint, different template, and carries the ORIGIN's first sighting plus a
# chain depth onto the successor.
#
# Traffic and detection are real. `POST /api/fault/template-mutation-sql` on
# order-service issues the same N+1 in two shapes, `b` adding `AND quantity > 0`,
# and the shared lab daemon detects both. Only the Hub half is isolated: the
# link is only ever created on the import that FIRST sees the successor
# signature, so a Hub that already knows both would silently prove nothing. A
# fresh namespace gives an empty database and control over the import order,
# which lineage requires (the predecessor must have been observed strictly
# earlier, not in the same batch).
#
# The isolated Hub polls nothing. Its Sources[0] exists only to carry the import
# key, and its one boot-time poll fails against a name that resolves nowhere.
# That is intentional: reachability is scenarios/hub-source-reachability's job.
#
# Sub-tests:
#   1. the two shapes yield two findings, same endpoint, different template
#   2. the successor carries lineage back to the predecessor, depth 1
#   3. origin_first_seen_ms is the PREDECESSOR's first sighting, not the
#      successor's own
#   4. `perf-sentinel diff` pairs the same two as a mutation, not resolved+new

set -euo pipefail

SCENARIO="hub-lineage-mutation"
NS="${HUB_LINEAGE_NS:-hub-lineage-mutation}"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"

HUB_PORT="${HUB_LINEAGE_HUB_PORT:-8093}"
ORDER_PORT="${HUB_LINEAGE_ORDER_PORT:-18093}"
DAEMON_PORT="${DAEMON_LOCAL_PORT:-14318}"
ENDPOINT="/api/fault/template-mutation-sql"
# 15 reaches the shared daemon's high-occurrence bar (3 x n_plus_one_min_occurrences
# of 5): under strict, the sanitized loop is then n_plus_one_sql on every request.
# At 12 the timing variance alone decides, and a warm JVM keeps it under
# sanitizer_aware_min_cv on most requests, so the shape reads as redundant_sql.
ITEMS="${HUB_LINEAGE_ITEMS:-15}"

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PF_HUB_PID=""; PF_ORDER_PID=""
cleanup() {
  [ -n "${PF_HUB_PID}" ] && kill "${PF_HUB_PID}" 2>/dev/null || true
  [ -n "${PF_ORDER_PID}" ] && kill "${PF_ORDER_PID}" 2>/dev/null || true
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

step "0. Pre-flight"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
HUB_IMAGE="$(kubectl -n observability get deploy/perf-sentinel-hub \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[ -n "${HUB_IMAGE}" ] || die "no Hub in the cluster. Run: make seed-hub-local"
kubectl -n shop get deploy/order-service >/dev/null 2>&1 \
  || die "no order-service in the cluster. Run: make seed-services"
curl -sf "http://127.0.0.1:${DAEMON_PORT}/health" >/dev/null \
  || die "the shared daemon is not reachable on ${DAEMON_PORT}. Run: make port-forward"
ok "shared daemon and order-service up, hub image ${HUB_IMAGE}"

command -v docker >/dev/null || die "docker not on PATH"
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
in_image() {
  docker run --rm -u "$(id -u):$(id -g)" -v "${TMP_DIR}:/workdir" "${IMAGE}" "$@"
}
ok "CLI image ${IMAGE}"

IMPORT_KEY="$(head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n')"

step "1. an isolated Hub with an empty database"
for _ in $(seq 1 60); do
  kubectl get namespace "${NS}" >/dev/null 2>&1 || break
  [ "$(kubectl get namespace "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Terminating" ] && break
  sleep 2
done
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${NS}" create secret generic hub-import-key \
  --from-literal=import-key="${IMPORT_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

python3 - "${TMP_DIR}/hub.yaml" "${NS}" "${HUB_IMAGE}" <<'PY'
import json, sys
out, ns, image = sys.argv[1], sys.argv[2], sys.argv[3]
settings = {"Hub": {
    "DatabasePath": "/data/hub.db",
    # Long enough that the worker's own cadence never fires during the run; the
    # one poll it does at boot fails against a name that resolves nowhere.
    "PollInterval": "23:00:00",
    "HttpTimeout": "00:00:02",
    "Retention": "180.00:00:00",
    "ResolutionGrace": "24:00:00",
    "MaxReadLimit": 10000,
    "Sources": [{
        "Id": "lab-daemon", "Name": "import only", "Environment": "lab",
        "BaseUrl": "http://no-poll-target.invalid:14318",
    }],
}}
indented = "\n".join("    " + line for line in json.dumps(settings, indent=2).splitlines())
open(out, "w").write(f"""---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hub-config
  namespace: {ns}
data:
  appsettings.Production.json: |
{indented}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hub
  namespace: {ns}
spec:
  replicas: 1
  strategy: {{type: Recreate}}
  selector: {{matchLabels: {{app: hub}}}}
  template:
    metadata:
      labels: {{app: hub}}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1654
        runAsGroup: 1654
        fsGroup: 1654
        seccompProfile: {{type: RuntimeDefault}}
      containers:
        - name: hub
          image: {image}
          imagePullPolicy: Never
          ports: [{{name: http, containerPort: 8080}}]
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: Production
            - name: Hub__Sources__0__ImportApiKey
              valueFrom:
                secretKeyRef: {{name: hub-import-key, key: import-key}}
          volumeMounts:
            - name: config
              mountPath: /app/appsettings.Production.json
              subPath: appsettings.Production.json
              readOnly: true
            - {{name: data, mountPath: /data}}
            - {{name: tmp, mountPath: /tmp}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {{drop: [ALL]}}
          startupProbe:
            httpGet: {{path: /health/ready, port: http}}
            failureThreshold: 40
            periodSeconds: 2
      volumes:
        - name: config
          configMap:
            name: hub-config
            items: [{{key: appsettings.Production.json, path: appsettings.Production.json}}]
        # emptyDir, not a PVC: the point of this Hub is that it starts empty.
        - {{name: data, emptyDir: {{}}}}
        - {{name: tmp, emptyDir: {{}}}}
---
apiVersion: v1
kind: Service
metadata:
  name: hub
  namespace: {ns}
spec:
  selector: {{app: hub}}
  ports: [{{name: http, port: 8080, targetPort: http}}]
""")
PY

kubectl apply -f "${TMP_DIR}/hub.yaml" >/dev/null
kubectl -n "${NS}" rollout status deploy/hub --timeout=180s >/dev/null \
  || die "the isolated Hub did not become ready: $(kubectl -n "${NS}" logs deploy/hub --tail=20 2>&1)"

# disown, so killing them in cleanup does not print job-control notices over
# the scenario verdict.
kubectl -n "${NS}" port-forward svc/hub "${HUB_PORT}:8080" >"${TMP_DIR}/pf-hub.log" 2>&1 &
PF_HUB_PID=$!
disown "${PF_HUB_PID}" 2>/dev/null || true
kubectl -n shop port-forward svc/order-service "${ORDER_PORT}:8080" >"${TMP_DIR}/pf-order.log" 2>&1 &
PF_ORDER_PID=$!
disown "${PF_ORDER_PID}" 2>/dev/null || true
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${HUB_PORT}/health/ready" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "http://127.0.0.1:${HUB_PORT}/health/ready" >/dev/null || die "isolated Hub not reachable"
ok "isolated Hub ready on ${HUB_PORT}"

# Pull one finding out of the shared daemon by its normalized SQL template.
# $1 = a substring the template must contain, $2 = one it must NOT.
# The service filter is not an optimization: unfiltered, the endpoint returns a
# capped page dominated by the synthetic traffic other scenarios inject, and the
# order-service findings never appear in it. The daemon serves ENVELOPES, so the
# bare finding has to be unwrapped before it can be re-imported.
daemon_finding() {
  curl -sf "http://127.0.0.1:${DAEMON_PORT}/api/findings?service=order-service&limit=1000" \
    | python3 -c '
import json, sys
want, avoid, endpoint = sys.argv[1], sys.argv[2], sys.argv[3]
for envelope in json.load(sys.stdin):
    f = envelope.get("finding") or envelope
    if f.get("source_endpoint") != endpoint or f.get("type") != "n_plus_one_sql":
        continue
    t = (f.get("pattern") or {}).get("template", "")
    if want in t and (not avoid or avoid not in t):
        json.dump(f, sys.stdout)
        break
' "$1" "$2" "${ENDPOINT}"
}

# Wrap a bare daemon finding in the import envelope and push it. One finding per
# call on purpose: the Hub only links a predecessor observed STRICTLY earlier,
# so the two shapes must arrive in two imports, not one batch.
push_one() {  # $1 = file holding the bare finding, echoes the HTTP status
  python3 - "$1" "${TMP_DIR}/envelope.json" <<'PY'
import json, sys, time
finding = json.load(open(sys.argv[1]))
now = int(time.time() * 1000)
json.dump({"producer_version": "lab-lineage", "findings": [
    {"stored_at_ms": now, "first_seen_ms": now, "seen_count": 1, "finding": finding},
]}, open(sys.argv[2], "w"))
PY
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:${HUB_PORT}/api/import/findings?source_id=lab-daemon" \
    -H "X-API-Key: ${IMPORT_KEY}" -H "Content-Type: application/json" \
    --data-binary "@${TMP_DIR}/envelope.json"
}

# === 1: two shapes, one endpoint, two templates ===
step "2. the two SQL shapes yield two findings on one endpoint"
for shape in a b; do
  for _ in 1 2 3; do
    curl -sf -o /dev/null -X POST \
      "http://127.0.0.1:${ORDER_PORT}${ENDPOINT}?shape=${shape}&items=${ITEMS}" \
      || die "the order-service fault endpoint refused shape=${shape}"
  done
done
# The daemon closes its correlation window and stores asynchronously.
for _ in $(seq 1 30); do
  daemon_finding "order_id = ?" "quantity" > "${TMP_DIR}/shape-a.json" || true
  daemon_finding "quantity" "" > "${TMP_DIR}/shape-b.json" || true
  [ -s "${TMP_DIR}/shape-a.json" ] && [ -s "${TMP_DIR}/shape-b.json" ] && break
  sleep 2
done
SIG_A="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["signature"])' "${TMP_DIR}/shape-a.json" 2>/dev/null || echo "")"
SIG_B="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["signature"])' "${TMP_DIR}/shape-b.json" 2>/dev/null || echo "")"
if [ -n "${SIG_A}" ] && [ -n "${SIG_B}" ] && [ "${SIG_A}" != "${SIG_B}" ]; then
  ok "two signatures on ${ENDPOINT}: ${SIG_A##*:} and ${SIG_B##*:}"
  record "two shapes detected" PASS "${SIG_A##*:} -> ${SIG_B##*:}"
else
  fail "expected two distinct findings on ${ENDPOINT}, got a='${SIG_A}' b='${SIG_B}'"
  record "two shapes detected" FAIL "a='${SIG_A}' b='${SIG_B}'"
  die "nothing further is provable without both shapes"
fi

# === 2: the successor links back ===
step "3. the successor carries lineage back to the predecessor"
CODE_A="$(push_one "${TMP_DIR}/shape-a.json")"
[ "${CODE_A}" = "200" ] || die "the predecessor import failed with HTTP ${CODE_A}"
# Strictly-earlier is a timestamp comparison in milliseconds, so the two imports
# must not land inside the same one.
sleep 2
CODE_B="$(push_one "${TMP_DIR}/shape-b.json")"
[ "${CODE_B}" = "200" ] || die "the successor import failed with HTTP ${CODE_B}"

curl -sf "http://127.0.0.1:${HUB_PORT}/api/findings?service=order-service&limit=1000" \
  > "${TMP_DIR}/hub-findings.json" || die "the Hub refused to serve its findings"
# The API publishes the chain as two numbers, `original_first_seen` and
# `predecessors`; the predecessor's signature stays internal to the Hub.
envelope_field() {  # $1 = signature, $2 = dotted path, echoes "" when absent
  python3 -c '
import json, sys
sig, path = sys.argv[2], sys.argv[3].split(".")
for e in json.load(open(sys.argv[1])):
    if (e.get("finding") or {}).get("signature") != sig:
        continue
    node = e
    for key in path:
        if not isinstance(node, dict) or key not in node:
            sys.exit(0)
        node = node[key]
    print(node)
    break
' "${TMP_DIR}/hub-findings.json" "$1" "$2"
}

DEPTH="$(envelope_field "${SIG_B}" lineage.predecessors)"
PRED_LINEAGE="$(envelope_field "${SIG_A}" lineage.predecessors)"
if [ "${DEPTH}" = "1" ] && [ -z "${PRED_LINEAGE}" ]; then
  ok "the successor reports 1 predecessor, the predecessor itself reports no lineage"
  record "lineage linked" PASS "predecessors=1 on the successor only"
else
  fail "successor predecessors='${DEPTH}', predecessor predecessors='${PRED_LINEAGE}' (expected 1 and none)"
  fail "successor envelope lineage: $(envelope_field "${SIG_B}" lineage)"
  record "lineage linked" FAIL "successor='${DEPTH}' predecessor='${PRED_LINEAGE}'"
fi

# === 3: the origin is the predecessor's own birth ===
step "4. original_first_seen points at the predecessor, not the successor"
ORIGIN="$(envelope_field "${SIG_B}" lineage.original_first_seen)"
SELF_FIRST="$(envelope_field "${SIG_B}" first_seen_ms)"
PRED_FIRST="$(envelope_field "${SIG_A}" first_seen_ms)"
if [ -n "${ORIGIN}" ] && [ "${ORIGIN}" = "${PRED_FIRST}" ] && [ "${ORIGIN}" -lt "${SELF_FIRST}" ]; then
  ok "origin ${ORIGIN} is the predecessor's first sighting, ${SELF_FIRST} the successor's own"
  record "origin preserved" PASS "origin < successor first_seen"
else
  fail "origin='${ORIGIN}' predecessor first_seen='${PRED_FIRST}' successor first_seen='${SELF_FIRST}'"
  fail "an origin equal to the successor's own first sighting would mean the age reset"
  record "origin preserved" FAIL "origin='${ORIGIN}'"
fi

# === 4: the CLI pairs the same two as a mutation ===
step "5. perf-sentinel diff pairs them as a mutation, not resolved+new"
# `diff` reads TRACES, not reports, so the two shapes are replayed as span sets
# built from the templates the live JDBC instrumentation actually produced.
# scenarios/diff-mutated-findings already pins the pairing rules on hand-written
# fixtures; what this leg adds is that a REAL emitted template pair, not an
# idealized one, is still what the matcher considers a mutation.
replay_spans() {  # $1 = daemon finding file, $2 = trace id, $3 = output
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
finding = json.load(open(sys.argv[1]))
trace, out = sys.argv[2], sys.argv[3]
template = finding["pattern"]["template"]
endpoint = finding["source_endpoint"]


def literal(i):
    # Replaying the normalized template verbatim would make every span
    # identical and the pipeline would report redundant_sql, not the N+1 the
    # daemon actually found. Put a varying literal back where the tokenizer
    # put the first placeholder, and a constant in any others.
    head, sep, tail = template.partition("?")
    return head + str(i + 1) + tail.replace("?", "0") if sep else template


spans = []
for i in range(finding["pattern"]["occurrences"]):
    spans.append({
        "timestamp": f"2026-06-05T10:00:00.{100 + i * 3:03d}Z",
        "trace_id": trace, "span_id": f"{trace}-sql-{i}",
        "service": finding["service"], "type": "sql", "operation": "SELECT",
        "target": literal(i), "duration_us": 900,
        "source": {"endpoint": endpoint, "method": "FaultController::templateMutationSql"},
        "code_function": "FaultController.templateMutationSql",
        "code_filepath": "order-service/src/main/java/com/perfsim/order/web/FaultController.java",
        "code_lineno": 82, "code_namespace": "com.perfsim.order.web",
    })
json.dump(spans, open(out, "w"))
PY
}
replay_spans "${TMP_DIR}/shape-a.json" t-before "${TMP_DIR}/before.json"
replay_spans "${TMP_DIR}/shape-b.json" t-after "${TMP_DIR}/after.json"
DIFF_OUT="${TMP_DIR}/diff.json"
if in_image diff --before /workdir/before.json --after /workdir/after.json \
  --format json > "${DIFF_OUT}" 2>"${TMP_DIR}/diff.err"; then
  DIFF_RC=0
else
  DIFF_RC=$?
fi
COUNTS="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d.get("new_findings") or []),
      len(d.get("resolved_findings") or []),
      len(d.get("mutated_findings") or []))
' "${DIFF_OUT}" 2>/dev/null || echo "-1 -1 -1")"
if [ "${COUNTS}" = "0 0 1" ]; then
  ok "diff reports 1 mutation and no resolved/new pair"
  record "diff pairs the mutation" PASS "0 new, 0 resolved, 1 mutated"
else
  fail "diff (rc ${DIFF_RC}) reported new/resolved/mutated = ${COUNTS}, expected 0 0 1"
  fail "stderr: $(head -c 300 "${TMP_DIR}/diff.err" 2>/dev/null)"
  record "diff pairs the mutation" FAIL "${COUNTS}"
fi

step "Report"
{
  echo "# ${SCENARIO}"
  echo
  echo "| sub-test | verdict | note |"
  echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
} > "${REPORT}"
step "Report written to ${REPORT}"

for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
