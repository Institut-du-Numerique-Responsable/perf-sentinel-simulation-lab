#!/usr/bin/env bash
# hub-disclosures: a CI publishes a periodic disclosure to the Hub, which checks
# and renders it with its embedded engine, shares it through an expiring link,
# pushes signed webhooks, and refuses what it must not keep.
#
# perf-sentinel 0.31.0 renders a disclosure as a PDF/A-3b (disclose-pdf) and
# verifies one (verify-hash --report report.pdf). PerfSentinelHub 0.7.0 takes it
# on POST /api/import/disclosures, serves its files under /share/<token>/, and
# signs a webhook per event. The lab has no Sigstore identity, so its reports are
# hash-only and the verdict expected throughout is PARTIAL: content hash and
# binding OK, signature not provided. TRUSTED is proven by the engine's
# disclosure-signing workflow.
#
# Legs, one numbered step each, on an isolated Hub:
#
#   0. Pre-flight. The local engine, a throwaway CA and a TLS relay, since
#      verify-hash --url takes https only, and a Hub with a webhook receiver
#      beside it in its pod (a webhook may be http to loopback only).
#   1. disclose with --emit-attestation, published: 201, PDF rendered, hash and
#      binding checked here.
#   2. A share link, then verify-hash --url on it: PARTIAL with the content hash
#      and the binding OK. verify-hash --report on the PDF the link serves: the same.
#   3. The figures edited: without a new hash, 422 content_hash_mismatch. With the
#      hash re-baked, 422 binding_mismatch. Nothing stored either way.
#   4. An internal report while AllowInternal is off: 422 internal_refused.
#   5. The receiver got "published" with a valid HMAC. A withdrawal sends
#      "withdrawn", HMAC valid too, and the share link answers 404 at once.
#
# Re-runnable. Everything lives in the scenario's own namespace, which the trap deletes.

set -euo pipefail

SCENARIO="hub-disclosures"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="${LAB_ROOT}/scenarios/disclose/fixtures"

NS="${OBS_NS:-observability}"
ISO_NS="${HUB_DISCLOSURES_NS:-hub-disclosures}"
ISO_HUB_PORT="${HUB_DISCLOSURES_HUB_PORT:-18098}"
TLS_PORT="${HUB_DISCLOSURES_TLS_PORT:-18443}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
# The fixtures' archive starts on 2026-06-05: an official period must not start earlier.
PERIOD_ARGS=(--period-type custom --from 2026-06-05 --to 2026-07-04)
# The delivery loop ticks every 15 s, and a first attempt follows its enqueueing.
DELIVERY_WAIT_S=45

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
check() { if [ "$2" = "yes" ]; then ok "$1"; record "$1" PASS "$3"; else fail "$1: $3"; record "$1" FAIL "$3"; fi; }

declare -a PIDS=()
cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "${pid}" 2>/dev/null || true; done
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${ISO_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
engine() { "${PERF_SENTINEL_LOCAL_BIN}" "$@"; }

# $1 = method, $2 = path, $3 = body file or JSON ("" for none). Prints the code, body in ${TMP_DIR}/body.
hub() {
  local args=(-s -o "${TMP_DIR}/body" -w '%{http_code}' -X "$1" -H "X-Forwarded-User: lab-operator")
  [ -n "${3:-}" ] && args+=(-H "content-type: application/json" -d "$3")
  curl "${args[@]}" "http://127.0.0.1:${ISO_HUB_PORT}$2"
}

# Publishes $1 (report) with the optional attestation $2. Prints the code, body in ${TMP_DIR}/body.
publish() {
  local args=(-s -o "${TMP_DIR}/body" -w '%{http_code}' -H "X-API-Key: ${IMPORT_KEY}" -F "report=@$1")
  [ -n "${2:-}" ] && args+=(-F "attestation=@$2")
  curl "${args[@]}" "http://127.0.0.1:${ISO_HUB_PORT}/api/import/disclosures"
}

stored_count() { hub GET /api/disclosures >/dev/null; jqp 'len(d)' < "${TMP_DIR}/body"; }

# The receiver's events, one JSON line each, with the HMAC each claims and whether it holds.
received() {
  kubectl -n "${ISO_NS}" logs deploy/hub -c receiver 2>/dev/null | python3 -c "
import hashlib, hmac, json, sys
secret = sys.argv[1].encode()
for line in sys.stdin:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    expected = 'sha256=' + hmac.new(secret, (r['ts'] + '.' + r['body']).encode(), hashlib.sha256).hexdigest()
    print(json.loads(r['body'])['event'], 'valid' if hmac.compare_digest(expected, r['sig']) else 'invalid')
" "${WEBHOOK_SECRET}"
}

step "0. Pre-flight"
for c in kubectl curl python3 openssl; do command -v "${c}" >/dev/null || die "${c} not on PATH"; done
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no engine at ${PERF_SENTINEL_LOCAL_BIN}: build it, or set PERF_SENTINEL_LOCAL_BIN"
engine disclose-pdf --help >/dev/null 2>&1 || die "${PERF_SENTINEL_LOCAL_BIN} has no disclose-pdf: it needs 0.31.0 or later"
HUB_IMAGE="${HUB_DISCLOSURES_HUB_IMAGE:-$(kubectl -n "${NS}" get deploy/perf-sentinel-hub -o jsonpath='{.spec.template.spec.containers[0].image}')}"
[ -n "${HUB_IMAGE}" ] || die "no Hub image to run. Run: make seed-hub-local (HUB_ENGINE_IMAGE before engine 0.31.0 is published)"
RECEIVER_IMAGE="${HUB_DISCLOSURES_RECEIVER_IMAGE:-lab-tracegen:1}"
IMPORT_KEY="$(openssl rand -hex 24)"
WEBHOOK_SECRET="$(openssl rand -hex 24)"

# A throwaway CA and a certificate for 127.0.0.1, for the relay below.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=hub-disclosures lab CA" \
  -keyout "${TMP_DIR}/ca.key" -out "${TMP_DIR}/ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=127.0.0.1" -keyout "${TMP_DIR}/tls.key" -out "${TMP_DIR}/tls.csr" >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1\n' > "${TMP_DIR}/san.ext"
openssl x509 -req -in "${TMP_DIR}/tls.csr" -CA "${TMP_DIR}/ca.pem" -CAkey "${TMP_DIR}/ca.key" -CAcreateserial \
  -days 1 -extfile "${TMP_DIR}/san.ext" -out "${TMP_DIR}/tls.pem" >/dev/null 2>&1

for _ in $(seq 1 60); do
  [ "$(kubectl get namespace "${ISO_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Terminating" ] || break
  sleep 2
done
kubectl create namespace "${ISO_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${ISO_NS}" create secret generic hub-keys \
  --from-literal=import-key="${IMPORT_KEY}" --from-literal=webhook-secret="${WEBHOOK_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - >/dev/null <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata: {name: hub-config, namespace: ${ISO_NS}}
data:
  appsettings.Production.json: |
    {"Hub": {
      "DatabasePath": "/data/hub.db",
      "PollInterval": "1.00:00:00",
      "AckRelay": {"TrustIdentityHeader": true},
      "Analysis": {"EngineBinaryPath": "/app/perf-sentinel", "ReportDirectory": "/data/reports"},
      "Sources": [{"Id": "lab-unused", "Name": "unused", "Environment": "lab", "BaseUrl": "http://127.0.0.1:1"}],
      "Disclosures": {
        "ShareLinkDays": 7,
        "Webhooks": [{"Name": "lab-receiver", "Url": "http://127.0.0.1:9090/hook"}]
      }
    }}
  receiver.py: |
    import http.server, json, sys
    class Hook(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('content-length', 0))).decode()
            print(json.dumps({'ts': self.headers.get('X-PerfSentinel-Timestamp'),
                              'sig': self.headers.get('X-PerfSentinel-Signature'), 'body': body}), flush=True)
            self.send_response(204)
            self.end_headers()
        def log_message(self, *args):
            pass
    http.server.HTTPServer(('127.0.0.1', 9090), Hook).serve_forever()
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
            - name: Hub__Disclosures__ImportKey
              valueFrom: {secretKeyRef: {name: hub-keys, key: import-key}}
            - name: Hub__Disclosures__Webhooks__0__Secret
              valueFrom: {secretKeyRef: {name: hub-keys, key: webhook-secret}}
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
        - name: receiver
          image: ${RECEIVER_IMAGE}
          imagePullPolicy: Never
          command: [python3, /receiver/receiver.py]
          volumeMounts:
            - {name: config, mountPath: /receiver, readOnly: true}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
      volumes:
        - name: config
          configMap: {name: hub-config}
        - name: data
          emptyDir: {}
        - name: tmp
          emptyDir: {}
EOF
kubectl -n "${ISO_NS}" rollout status deploy/hub --timeout=180s >/dev/null || die "the isolated Hub never became ready"
kubectl -n "${ISO_NS}" port-forward deploy/hub "${ISO_HUB_PORT}:8080" >/dev/null 2>&1 &
PIDS+=($!)
# The relay terminates TLS with the lab CA and forwards GET to the port-forward,
# so verify-hash --url reaches the share route over https as an auditor would.
python3 - "${TLS_PORT}" "${ISO_HUB_PORT}" "${TMP_DIR}/tls.pem" "${TMP_DIR}/tls.key" >/dev/null 2>&1 <<'PY' &
import http.server, ssl, sys, urllib.request, urllib.error
port, upstream, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
class Relay(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{upstream}{self.path}") as r:
                status, headers, body = r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            status, headers, body = e.code, e.headers, e.read()
        self.send_response(status)
        for name in ("Content-Type", "Content-Disposition", "Cache-Control", "Referrer-Policy"):
            if headers.get(name):
                self.send_header(name, headers[name])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server = http.server.HTTPServer(("127.0.0.1", port), Relay)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
PIDS+=($!)
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:${ISO_HUB_PORT}/health/ready" && break; sleep 1; done
for _ in $(seq 1 30); do curl -s -o /dev/null --cacert "${TMP_DIR}/ca.pem" "https://127.0.0.1:${TLS_PORT}/share/" && break; sleep 1; done
cp "${FIXTURES}/reports-thr5.ndjson" "${FIXTURES}/org-config.toml" "${TMP_DIR}/"
ok "Hub ${HUB_IMAGE} up in ${ISO_NS}, relay https://127.0.0.1:${TLS_PORT}, engine $(engine --version)"

step "1. A signed-off disclosure published by CI"
engine disclose --intent official --confidentiality public "${PERIOD_ARGS[@]}" \
  --input "${TMP_DIR}/reports-thr5.ndjson" --org-config "${TMP_DIR}/org-config.toml" \
  --output "${TMP_DIR}/report.json" --emit-attestation "${TMP_DIR}/attestation.intoto.jsonl" >/dev/null 2>&1 \
  || die "disclose failed on the fixtures"
CODE="$(publish "${TMP_DIR}/report.json" "${TMP_DIR}/attestation.intoto.jsonl")"
cp "${TMP_DIR}/body" "${TMP_DIR}/published.json"
ID="$(jqp "d.get('id','')" < "${TMP_DIR}/published.json")"
CHECKS="$(jqp "f\"{d.get('pdf')} {d.get('content_hash_checked')} {d.get('binding_checked')}\"" < "${TMP_DIR}/published.json")"
check "published: 201, PDF rendered, hash and binding checked here" \
  "$([ "${CODE}" = "201" ] && [ "${CHECKS}" = "rendered True True" ] && echo yes || echo no)" "code ${CODE}, ${CHECKS}"

step "2. A share link, verified from outside"
hub POST "/api/disclosures/${ID}/share-links" '{"days": 2}' > "${TMP_DIR}/code"
TOKEN="$(jqp "d.get('token','')" < "${TMP_DIR}/body")"
SHARE="https://127.0.0.1:${TLS_PORT}/share/${TOKEN}"
set +e
URL_OUT="$(SSL_CERT_FILE="${TMP_DIR}/ca.pem" engine verify-hash --url "${SHARE}/report.json" 2>&1)"; URL_EXIT=$?
set -e
check "verify-hash --url on the share link: PARTIAL, content hash and binding OK" \
  "$([ "${URL_EXIT}" = "2" ] && [[ "${URL_OUT}" == *"[OK] Content hash"* ]] && [[ "${URL_OUT}" == *"[OK] Attestation binding"* ]] && echo yes || echo no)" \
  "exit ${URL_EXIT}"
curl -s --cacert "${TMP_DIR}/ca.pem" -o "${TMP_DIR}/shared.pdf" "${SHARE}/report.pdf"
set +e
PDF_OUT="$(engine verify-hash --report "${TMP_DIR}/shared.pdf" 2>&1)"; PDF_EXIT=$?
set -e
check "verify-hash --report on the shared PDF: PARTIAL, content hash and binding OK" \
  "$([ "${PDF_EXIT}" = "2" ] && [[ "${PDF_OUT}" == *"[OK] Content hash"* ]] && [[ "${PDF_OUT}" == *"[OK] Attestation binding"* ]] && echo yes || echo no)" \
  "exit ${PDF_EXIT}"

step "3. Edited figures are refused and nothing is stored"
python3 - "${TMP_DIR}/report.json" "${TMP_DIR}/edited.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["report_metadata"]["report_uuid"] = "00000000-0000-4000-8000-0000000e0001"
r["aggregate"]["total_energy_kwh"] = r["aggregate"]["total_energy_kwh"] / 2
json.dump(r, open(sys.argv[2], "w"))
PY
CODE="$(publish "${TMP_DIR}/edited.json" "${TMP_DIR}/attestation.intoto.jsonl")"
REASON="$(jqp "d.get('reason','')" < "${TMP_DIR}/body")"
check "edited figures, hash not re-baked: 422 content_hash_mismatch" \
  "$([ "${CODE}" = "422" ] && [ "${REASON}" = "content_hash_mismatch" ] && echo yes || echo no)" "code ${CODE}, ${REASON}"
engine hash-bake --report "${TMP_DIR}/edited.json" --output "${TMP_DIR}/rebaked.json" >/dev/null 2>&1
CODE="$(publish "${TMP_DIR}/rebaked.json" "${TMP_DIR}/attestation.intoto.jsonl")"
REASON="$(jqp "d.get('reason','')" < "${TMP_DIR}/body")"
check "edited figures, hash re-baked: 422 binding_mismatch" \
  "$([ "${CODE}" = "422" ] && [ "${REASON}" = "binding_mismatch" ] && echo yes || echo no)" "code ${CODE}, ${REASON}"
COUNT="$(stored_count)"
check "nothing stored from a refused publication" "$([ "${COUNT}" = "1" ] && echo yes || echo no)" "${COUNT} stored"

step "4. An internal report while AllowInternal is off"
engine disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
  --input "${TMP_DIR}/reports-thr5.ndjson" --org-config "${TMP_DIR}/org-config.toml" \
  --output "${TMP_DIR}/internal.json" >/dev/null 2>&1 || die "internal disclose failed"
CODE="$(publish "${TMP_DIR}/internal.json")"
REASON="$(jqp "d.get('reason','')" < "${TMP_DIR}/body")"
check "internal report: 422 internal_refused" \
  "$([ "${CODE}" = "422" ] && [ "${REASON}" = "internal_refused" ] && echo yes || echo no)" "code ${CODE}, ${REASON}"

step "5. Signed webhooks, then a withdrawal that kills the link"
EVENTS=""
for _ in $(seq 1 "${DELIVERY_WAIT_S}"); do
  EVENTS="$(received | tr '\n' ' ')"
  [[ "${EVENTS}" == *"published"* ]] && break
  sleep 1
done
check "the receiver got published with a valid HMAC" \
  "$([[ "${EVENTS}" == *"published valid"* ]] && echo yes || echo no)" "${EVENTS:-nothing}"
CODE="$(hub POST "/api/disclosures/${ID}/withdraw" '{"reason":"lab withdrawal"}')"
LINK="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${TMP_DIR}/ca.pem" "${SHARE}/report.json")"
check "withdrawn: 204, and the share link answers 404 at once" \
  "$([ "${CODE}" = "204" ] && [ "${LINK}" = "404" ] && echo yes || echo no)" "withdraw ${CODE}, link ${LINK}"
for _ in $(seq 1 "${DELIVERY_WAIT_S}"); do
  EVENTS="$(received | tr '\n' ' ')"
  [[ "${EVENTS}" == *"withdrawn"* ]] && break
  sleep 1
done
check "the receiver got withdrawn with a valid HMAC" \
  "$([[ "${EVENTS}" == *"withdrawn valid"* ]] && echo yes || echo no)" "${EVENTS:-nothing}"

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Hub: \`${HUB_IMAGE}\`"
  echo
  echo "Engine: \`$(engine --version)\` at \`${PERF_SENTINEL_LOCAL_BIN}\`"
  echo
  echo "Isolated Hub in namespace \`${ISO_NS}\`, webhook receiver beside it, share route over a TLS relay with a throwaway CA."
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
