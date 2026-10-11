#!/usr/bin/env bash
# appsec-hardening: validate the 0.9.15 AppSec remediation behaviours.
#
#   A. Ingest redaction: query string, fragment and userinfo are stripped from
#      source_endpoint (and therefore the ack signature) when the endpoint
#      comes from a raw URL, '@' in a path and route templates are untouched.
#      (0.9.14 leaks "user:pass@...?token=SECRET#frag" verbatim.)
#   B. Ack API key: GET /api/acks returns 401 without X-API-Key when a key is
#      configured, 200 with it. PERF_SENTINEL_ACK_API_KEY overrides the TOML
#      key. (0.9.14 served GET without any key.) [daemon] read_api_key (0.20.0)
#      answers 200 on GET /api/acks and 401 on POST /api/findings/{sig}/ack:
#      a read key never writes.
#   C. /api/export/report evaluates the real quality gate: three rules are
#      always present (0.9.14 hardcoded passed:true, rules:[]), and a critical
#      N+1 SQL finding with n_plus_one_sql_critical_max=0 flips passed:false.
#   D. verify-hash: binary_attestation is a post-sign field (the content hash
#      still validates after injection), the report caps at PARTIAL (exit 2)
#      with a hint to the new --verify-binary flag (absent from 0.9.14).
#   E. Non-loopback bind logs the widened advisory but the daemon still serves
#      (warning, not a refusal).
#
# Self-contained: needs only the local release binary (>= 0.20.0 for the
# read key in leg B).
set -euo pipefail

SCENARIO="appsec-hardening"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
ORG_CONFIG="${REPO_ROOT}/scenarios/disclose/fixtures/org-config.toml"
mkdir -p "${TMP_DIR}"
# A stale PASS report from a previous run must not survive a failing re-run.
rm -f "${REPORT}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14406}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14407}"
BIND_HTTP_PORT="${BIND_HTTP_PORT:-14408}"
BIND_GRPC_PORT="${BIND_GRPC_PORT:-14409}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
# AF_UNIX path must stay short (~104 char limit), so /tmp not the scratch dir.
SOCK="${SOCK:-/tmp/ps-ah-$$.sock}"
# api_key validation requires >= 12 chars (16 recommended), env-sourced keys included
TOML_KEY="lab-toml-key-000"
ENV_KEY="lab-env-key-0000"
# Must differ from the ack key of every daemon this script starts (TOML in
# one run, env in the other): equal to it, it would be that key.
READ_KEY="lab-read-key-0000"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

DAEMON_PID=""
cleanup() { [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true; rm -f "${SOCK}" "${SOCK}e" 2>/dev/null || true; }
trap cleanup EXIT

step "0. Pre-flight"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v jq >/dev/null      || die "jq not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
[ -f "${FIX}/appsec.native.json" ] || die "fixture missing: ${FIX}/appsec.native.json"
[ -f "${ORG_CONFIG}" ]             || die "org-config missing: ${ORG_CONFIG}"
ok "binary $(basename "${PERF_SENTINEL_LOCAL_BIN}") $("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"

# =============================================================================
step "A. batch analyze: query/fragment/userinfo stripped from source_endpoint"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/appsec.native.json" --format json \
  > "${TMP_DIR}/analyze.json" 2>/dev/null || die "analyze failed"
ENDPOINTS="$(jq -r '.findings[].source_endpoint' "${TMP_DIR}/analyze.json")"
SIGS="$(jq -r '.findings[].signature' "${TMP_DIR}/analyze.json")"
# Positive anchor first: signatures must exist and be inspectable, otherwise
# the leak greps below pass vacuously (field renamed/dropped upstream).
echo "${SIGS}" | grep -q '^n_plus_one_sql:' || die "no usable finding signature (field renamed?): ${SIGS}"
echo "${ENDPOINTS}" | grep -qx 'http://shop-svc/api/orders' || die "stripped endpoint absent, got: ${ENDPOINTS}"
printf '%s\n%s\n' "${ENDPOINTS}" "${SIGS}" | grep -q '[?#]' && die "query/fragment delimiter leaked into an endpoint or signature"
# Also hunt the secret material itself: a redactor that drops delimiters but
# keeps the query/userinfo text would pass the delimiter grep above.
printf '%s\n%s\n' "${ENDPOINTS}" "${SIGS}" | grep -qE 'SECRET|token=|frag|user:pass' && die "secret material leaked into an endpoint or signature"
echo "${ENDPOINTS}" | grep -qx '/users/a@b.example/orders' || die "'@' inside a path was wrongly stripped"
echo "${ENDPOINTS}" | grep -qx 'GET /api/orders/{id}'      || die "route template was altered"
CRIT_SEV="$(jq -r '.findings[] | select(.source_endpoint=="http://shop-svc/api/orders") | .severity' "${TMP_DIR}/analyze.json")"
echo "${CRIT_SEV}" | grep -qx 'critical' || die "expected the 12-occurrence N+1 to be critical, got ${CRIT_SEV}"
record "A-redaction" "PASS" "stripped endpoint + signature, path-@ and route template preserved"
ok "endpoint stripped to http://shop-svc/api/orders (critical), path-@ and template intact"

# =============================================================================
write_daemon_toml() {  # $1 = listen address, $2 = http port, $3 = grpc port, $4 = socket
  cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "$1"
listen_port_http = $2
listen_port_grpc = $3
json_socket = "$4"
api_enabled = true
trace_ttl_ms = 1500
read_api_key = "${READ_KEY}"

[daemon.ack]
enabled = true
api_key = "${TOML_KEY}"
storage_path = "${TMP_DIR}/acks.jsonl"

[thresholds]
n_plus_one_sql_critical_max = 0

[detection]
n_plus_one_min_occurrences = 5
EOF
}

start_daemon() {  # $1... = env wrapper command prefix (env -u VAR | env VAR=x)
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  # The ports are fixed: wait until nothing serves them anymore, then require
  # silence before spawning, so the daemon that later answers readiness is OURS
  # (a leftover from an aborted run would otherwise pass with a stale binary).
  for _ in $(seq 1 20); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 || break
    sleep 0.5
  done
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
    && die "something already serves ${DAEMON_URL} - leftover daemon from a previous run?"
  rm -f "${SOCK}"
  "$@" "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && break
    sleep 0.5
  done
  kill -0 "${DAEMON_PID}" 2>/dev/null || die "spawned daemon died: $(tail -3 "${TMP_DIR}/daemon.log")"
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 || die "daemon not ready: $(tail -3 "${TMP_DIR}/daemon.log")"
}

acks_code() {  # $1 = optional api key ("" = no header)
  if [ -n "$1" ]; then
    curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $1" "${DAEMON_URL}/api/acks"
  else
    curl -s -o /dev/null -w '%{http_code}' "${DAEMON_URL}/api/acks"
  fi
}

acks_auth() {  # $1 = raw Authorization header value
  curl -s -o /dev/null -w '%{http_code}' -H "Authorization: $1" "${DAEMON_URL}/api/acks"
}

ack_post() {  # $1 = header name, $2 = header value
  curl -s -o /dev/null -w '%{http_code}' -X POST -H "$1: $2" \
    -H "Content-Type: application/json" -d '{}' \
    "${DAEMON_URL}/api/findings/0123456789abcdef0123456789abcdef/ack"
}

# Sum every unauthorized ack failure, whatever the action label, so the
# assertion does not pin a label spelling that is not its subject.
ack_unauth() {
  curl -s "${DAEMON_URL}/metrics" \
    | awk '/^perf_sentinel_ack_operations_failed_total\{.*reason="unauthorized".*\}/ {n += $2} END {print n + 0}'
}

step "B1/B2. ack key from TOML: GET /api/acks 401 bare, 200 with the key"
write_daemon_toml "127.0.0.1" "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}" "${SOCK}"
start_daemon env -u PERF_SENTINEL_ACK_API_KEY
code="$(acks_code "")"
[ "${code}" = "401" ] || die "expected 401 without X-API-Key, got ${code}"
code="$(acks_code "${TOML_KEY}")"
[ "${code}" = "200" ] || die "expected 200 with the TOML key, got ${code}"
record "B-toml-key" "PASS" "401 bare / 200 with X-API-Key (0.9.14 served bare GET)"
ok "GET /api/acks gated by the TOML key"

step "B. [daemon] read_api_key: GET /api/acks 200, POST /api/findings/{sig}/ack 401"
code="$(acks_code "${READ_KEY}")"
[ "${code}" = "200" ] || die "expected 200 on GET /api/acks with the read key, got ${code}"
# Every AckRequest field is optional, so an empty object reaches the auth check.
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-API-Key: ${READ_KEY}" \
  -H "Content-Type: application/json" -d '{}' \
  "${DAEMON_URL}/api/findings/0123456789abcdef0123456789abcdef/ack")"
[ "${code}" = "401" ] || die "expected 401 on POST ack with the read key, got ${code}"
record "B-read-key" "PASS" "read key: GET /api/acks 200, POST ack 401 (0.20.0)"
ok "the read key opens GET /api/acks and never the ack POST"

step "B5. The same ack gate, reached by a bearer token (0.22.0)"
# The ack routes gained `Authorization: Bearer` alongside `X-API-Key` in the
# same change that gave it to the incidents route. Same key, same constant-time
# comparison, and the read key keeps its read-only shape in bearer form too.
code="$(acks_auth "Bearer ${TOML_KEY}")"
[ "${code}" = "200" ] || die "expected 200 on GET /api/acks with the ack key as bearer, got ${code}"
code="$(acks_auth "Bearer ${READ_KEY}")"
[ "${code}" = "200" ] || die "expected 200 on GET /api/acks with the read key as bearer, got ${code}"
code="$(acks_auth "Basic ${TOML_KEY}")"
[ "${code}" = "401" ] || die "Basic accepted on GET /api/acks, got ${code}"
code="$(ack_post "Authorization" "Bearer ${READ_KEY}")"
[ "${code}" = "401" ] || die "the read key wrote an ack in bearer form, got ${code}"

# The write verb: both credentials must decide the SAME way. The signature does
# not exist, so the status is the store's business and not this leg's subject.
c_hdr="$(ack_post "X-API-Key" "${TOML_KEY}")"
c_bearer="$(ack_post "Authorization" "Bearer ${TOML_KEY}")"
[ "${c_hdr}" = "${c_bearer}" ] \
  || die "header and bearer disagree on POST ack: ${c_hdr} vs ${c_bearer}"
[ "${c_hdr}" != "401" ] || die "the ack key was refused on POST ack under both headers"
record "B-bearer" "PASS" "GET 200 under both keys as bearer, Basic 401, read key never writes, POST ack agrees (${c_hdr})"
ok "bearer opens the ack gate exactly where the header does"

step "B6. A refused read is not an ack failure, and a refused write is"
# Deliberate asymmetry, stated in query_api/mod.rs: a denied GET /api/acks is
# not an ack mutation and has no AckAction to be recorded under, so it moves no
# counter. Someone debugging a 401 on the read path will find nothing in
# /metrics, and that is by design rather than an oversight.
U0="$(ack_unauth)"
acks_auth "Basic ${TOML_KEY}" >/dev/null
U1="$(ack_unauth)"
ack_post "Authorization" "Bearer wrong-key-0000" >/dev/null
U2="$(ack_unauth)"
if [ "${U1}" = "${U0}" ] && [ "${U2}" -gt "${U1}" ]; then
  record "B-metric-asymmetry" "PASS" "refused GET moves nothing (${U0}), refused POST does (${U2})"
  ok "a refused read is silent in /metrics, a refused write is counted"
else
  die "ack_operations_failed_total{reason=unauthorized}: ${U0} -> ${U1} (GET) -> ${U2} (POST)"
fi

step "C1. cold export: real quality-gate rules evaluated, passed=true"
# The point is that the cold envelope carries REAL evaluated rules rather than an
# empty list (0.9.14 returned rules:0), so the assertion is a floor plus the
# observed count, not an exact match. Pinning the exact number broke the moment
# the product added a fourth rule, which is a legitimate addition.
COLD_PASSED="$(curl -fsS "${DAEMON_URL}/api/export/report" | jq -r '.quality_gate.passed')"
COLD_RULES="$(curl -fsS "${DAEMON_URL}/api/export/report" | jq -r '.quality_gate.rules | length')"
[ "${COLD_PASSED}" = "true" ] || die "cold quality_gate.passed=${COLD_PASSED}, expected true"
[ "${COLD_RULES}" -ge 3 ] 2>/dev/null \
  || die "cold quality_gate carries ${COLD_RULES} rule(s), expected at least 3 (0.9.14 returns 0)"
record "C-cold-rules" "PASS" "${COLD_RULES} rules evaluated on the cold envelope (>= 3; 0.9.14: rules:[])"
ok "cold envelope carries ${COLD_RULES} evaluated rules, passed=true"

step "C2. critical N+1 SQL vs n_plus_one_sql_critical_max=0: passed=false"
python3 -c "
import socket, json
ev=[{'timestamp':'2025-06-07T12:00:00.%03dZ'%(i*4),'trace_id':'tqg','span_id':'sq%05d'%i,
     'parent_span_id':'sq00000','service':'appsec-svc','cloud_region':'eu-west-3','type':'sql',
     'operation':'SELECT','target':'SELECT * FROM orders WHERE id = %d'%i,'duration_us':2000,
     'source':{'endpoint':'/api/orders','method':'h'}} for i in range(1,13)]
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect('${SOCK}')
s.sendall((json.dumps(ev)+'\n').encode()); s.close()
"
# Poll instead of a fixed sleep: the trace finalizes at trace_ttl_ms=1500 and
# the async analysis worker publishes the finding some time after that.
GATE=""
for _ in $(seq 1 20); do
  GATE="$(curl -fsS "${DAEMON_URL}/api/export/report" | jq -c '.quality_gate')"
  echo "${GATE}" | jq -e '.passed == false' >/dev/null 2>&1 && break
  sleep 1
done
echo "${GATE}" | jq -e '.passed == false' >/dev/null || die "expected passed:false, got ${GATE}"
echo "${GATE}" | jq -e '.rules[] | select(.rule=="n_plus_one_sql_critical_max" and .passed==false and .actual>=1)' >/dev/null \
  || die "n_plus_one_sql_critical_max rule did not trip: ${GATE}"
record "C-gate-fails" "PASS" "critical N+1 trips the real gate (threshold 0)"
ok "live findings flip the exported gate to passed:false"

step "B3/B4. PERF_SENTINEL_ACK_API_KEY overrides the TOML key"
start_daemon env "PERF_SENTINEL_ACK_API_KEY=${ENV_KEY}"
code="$(acks_code "${TOML_KEY}")"
[ "${code}" = "401" ] || die "TOML key still accepted (got ${code}), env override lost"
code="$(acks_code "${ENV_KEY}")"
[ "${code}" = "200" ] || die "env key rejected, got ${code}"
record "B-env-key" "PASS" "env var beats the TOML key (Secret-friendly)"
ok "env key wins over the TOML key"
code="$(acks_auth "Bearer ${ENV_KEY}")"
[ "${code}" = "200" ] || die "env key refused as bearer, got ${code}"
code="$(acks_auth "Bearer ${TOML_KEY}")"
[ "${code}" = "401" ] || die "TOML key still accepted as bearer, env override lost on that path"
record "B-env-bearer" "PASS" "the env override governs the bearer path too"
ok "the env override wins on the bearer path as well"
kill "${DAEMON_PID}" 2>/dev/null || true; DAEMON_PID=""

# =============================================================================
step "D. verify-hash: binary_attestation caps at PARTIAL, hash unaffected"
jq -c '{report: ., ts: "2026-05-15T12:00:00Z"}' "${TMP_DIR}/analyze.json" > "${TMP_DIR}/windows.ndjson"
"${PERF_SENTINEL_LOCAL_BIN}" disclose --intent internal --confidentiality internal \
  --period-type calendar-quarter --from 2026-04-01 --to 2026-06-30 \
  --input "${TMP_DIR}/windows.ndjson" --output "${TMP_DIR}/report.json" \
  --org-config "${ORG_CONFIG}" > "${TMP_DIR}/disclose.log" 2>&1 || { tail -5 "${TMP_DIR}/disclose.log"; die "disclose failed"; }
"${PERF_SENTINEL_LOCAL_BIN}" hash-bake --report "${TMP_DIR}/report.json" --output "${TMP_DIR}/baked.json" >/dev/null 2>&1 || die "hash-bake failed"
"${PERF_SENTINEL_LOCAL_BIN}" verify-hash --help 2>&1 | grep -q -- '--verify-binary' || die "--verify-binary flag missing (0.9.14 binary?)"

set +e
"${PERF_SENTINEL_LOCAL_BIN}" verify-hash --report "${TMP_DIR}/baked.json" --no-identity-check --format json \
  2>/dev/null > "${TMP_DIR}/vh-control.json"; code_ctl=$?
set -e
[ "${code_ctl}" -eq 2 ] || die "control verify-hash: expected exit 2, got ${code_ctl}"
jq -e '.verifications.content_hash.status=="ok" and .verifications.binary_attestation.status=="not_provided"' \
  "${TMP_DIR}/vh-control.json" >/dev/null || die "control verdict unexpected: $(cat "${TMP_DIR}/vh-control.json")"

# binary_attestation is a post-sign field: injecting it AFTER hash-bake must
# leave the content hash valid while capping the overall verdict.
jq '.integrity.binary_attestation = {format:"slsa-provenance-v1",
      attestation_url:"https://github.com/Institut-du-Numerique-Responsable/perf-sentinel/releases/download/v0.9.15/perf-sentinel-linux-amd64.intoto.jsonl",
      builder_id:"https://github.com/actions/runner",git_tag:"v0.9.15",
      git_commit:"0bffc037",slsa_level:"L2"}' \
  "${TMP_DIR}/baked.json" > "${TMP_DIR}/attested.json"
set +e
"${PERF_SENTINEL_LOCAL_BIN}" verify-hash --report "${TMP_DIR}/attested.json" --no-identity-check --format json \
  2>/dev/null > "${TMP_DIR}/vh-attested.json"; code_att=$?
set -e
[ "${code_att}" -eq 2 ] || die "attested verify-hash: expected exit 2 (PARTIAL cap), got ${code_att}"
jq -e '.verifications.content_hash.status=="ok"
       and .verifications.binary_attestation.status=="skip"
       and (.verifications.binary_attestation.detail | contains("--verify-binary <path>"))
       and .overall=="PARTIAL"' "${TMP_DIR}/vh-attested.json" >/dev/null \
  || die "attested verdict unexpected: $(cat "${TMP_DIR}/vh-attested.json")"
record "D-attestation-cap" "PASS" "post-sign injection keeps hash ok, caps PARTIAL, hints --verify-binary"
ok "attested report capped at PARTIAL with the --verify-binary hint (flag absent from 0.9.14)"

# =============================================================================
step "E. non-loopback bind: advisory logged, daemon still serves"
write_daemon_toml "0.0.0.0" "${BIND_HTTP_PORT}" "${BIND_GRPC_PORT}" "${SOCK}e"
DAEMON_URL="http://127.0.0.1:${BIND_HTTP_PORT}"
start_daemon env -u PERF_SENTINEL_ACK_API_KEY
grep -q "non-loopback" "${TMP_DIR}/daemon.log" || die "non-loopback advisory absent from the daemon log"
kill "${DAEMON_PID}" 2>/dev/null || true; DAEMON_PID=""

# Discriminator for the 0.9.15 WIDENING: "[::1]" is loopback to the new
# range-parsing matcher but not to the old two-spelling string compare, so the
# advisory must be ABSENT here (0.9.14 logs it on this exact bind).
write_daemon_toml "[::1]" "${BIND_HTTP_PORT}" "${BIND_GRPC_PORT}" "${SOCK}e"
DAEMON_URL="http://[::1]:${BIND_HTTP_PORT}"
start_daemon env -u PERF_SENTINEL_ACK_API_KEY
grep -q "non-loopback" "${TMP_DIR}/daemon.log" && die "widened matcher regressed: advisory fired on [::1]"
record "E-bind-warns" "PASS" "0.0.0.0 warns+serves; [::1] silent (widened-matcher discriminator)"
ok "0.0.0.0 warns, [::1] silent - the widening is pinned"
kill "${DAEMON_PID}" 2>/dev/null || true; DAEMON_PID=""

# =============================================================================
step "Summary"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "| check | verdict | note |"
  echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
  echo ""
  echo "Verdict: **PASS**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
