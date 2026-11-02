#!/usr/bin/env bash
# daemon-security-hardening: three 0.41.0 hardening gates of the daemon's HTTP
# listener, against a throwaway container of the image under test.
#
# Assertions (see README.md):
#   O1  an OTLP HTTP export of 100,001 empty spans answers 413
#   O2  perf_sentinel_otlp_rejected_total{reason="too_many_spans"} grew by 1
#   O3  the same export with 10 empty spans answers 200 (control)
#   H1  with [daemon] allowed_hosts set, a foreign Host answers 421
#   H2  a listed Host answers 200, and so do localhost and an IP literal
#   A1  with an ack key set, GET /api/findings?include_acked=true without a key answers 401
#   A2  the same request with the ack key answers 200
#   A3  GET /api/findings without include_acked stays open (200)
#
# Needs Docker, curl and python3. The image resolves through
# scripts/resolve-image.sh.
set -uo pipefail

SCENARIO="daemon-security-hardening"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"
PORT="${PORT:-15440}"
NAME="dsh-daemon"
URL="http://127.0.0.1:${PORT}"
ALLOWED_HOST="perf-sentinel.lab.internal"
ACK_KEY="dsh-ack-key-0123456789"
METRIC='perf_sentinel_otlp_rejected_total{reason="too_many_spans"}'

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }
# expect <id> <wanted code> <description> <curl args...>
expect() {
  local id="$1" want="$2" what="$3" got
  shift 3
  got="$(curl -s -o "${TMP_DIR}/${id}.body" -w '%{http_code}' --max-time 20 "$@")"
  if [ "${got}" = "${want}" ]; then
    assert_pass "${id}" "${what}: ${got}"
  else
    assert_fail "${id}" "${what}: wanted ${want}, got ${got} $(head -c 200 "${TMP_DIR}/${id}.body")"
  fi
}
counter() {
  curl -fsS "${URL}/metrics" | awk -v m="${METRIC}" '$1 == m { printf "%.0f\n", $2; found=1 } END { if (!found) print 0 }'
}

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

command -v docker >/dev/null || die "docker not found"
command -v curl >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"
step "image under test: ${IMAGE}"

rm -rf "${TMP_DIR}" "${REPORT}"
mkdir -p "${TMP_DIR}"
cleanup

# 0.0.0.0 so the published port reaches the daemon. On a non-loopback bind the
# Host check applies only once allowed_hosts is set, which is what H1/H2 pin.
cat > "${TMP_DIR}/config.toml" <<EOF
[daemon]
listen_address = "0.0.0.0"
allowed_hosts = ["${ALLOWED_HOST}"]

[daemon.ack]
api_key = "${ACK_KEY}"
storage_path = "/data/acks.jsonl"
EOF

# Empty spans cost two bytes each on the wire: field 2 of ScopeSpans, length 0.
python3 - "${TMP_DIR}" <<'PY'
import sys

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)

def wrap(tag, inner):
    return bytes([tag]) + varint(len(inner)) + inner

for name, spans in (("flood", 100_001), ("small", 10)):
    scope = b"\x12\x00" * spans                     # ScopeSpans.spans
    request = wrap(0x0A, wrap(0x12, scope))         # resource_spans > scope_spans
    open(f"{sys.argv[1]}/{name}.pb", "wb").write(request)
PY

docker run -d --name "${NAME}" --tmpfs /data:rw,mode=1777 \
  -v "${TMP_DIR}/config.toml:/etc/perf-sentinel/config.toml:ro" \
  -p "127.0.0.1:${PORT}:4318" \
  "${IMAGE}" watch -c /etc/perf-sentinel/config.toml >/dev/null || die "cannot start ${IMAGE}"
for _ in $(seq 40); do curl -sf "${URL}/health" >/dev/null && break; sleep 0.5; done
curl -sf "${URL}/health" >/dev/null || { docker logs "${NAME}" > "${TMP_DIR}/daemon.log" 2>&1; die "daemon never answered /health, see ${TMP_DIR}/daemon.log"; }
ok "daemon $(curl -fsS "${URL}/api/status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version"))') on ${URL}"

# =============================================================================
step "O: OTLP pre-decode span budget"
BEFORE="$(counter)"
expect O1 413 "100,001 empty spans over OTLP HTTP" -X POST -H 'Content-Type: application/x-protobuf' \
  --data-binary "@${TMP_DIR}/flood.pb" "${URL}/v1/traces"
AFTER="$(counter)"
if [ "$((AFTER - BEFORE))" = "1" ]; then
  assert_pass O2 "${METRIC} ${BEFORE} -> ${AFTER}"
else
  assert_fail O2 "${METRIC} ${BEFORE} -> ${AFTER}, wanted +1"
fi
expect O3 200 "10 empty spans over OTLP HTTP" -X POST -H 'Content-Type: application/x-protobuf' \
  --data-binary "@${TMP_DIR}/small.pb" "${URL}/v1/traces"

# =============================================================================
step "H: [daemon] allowed_hosts"
expect H1 421 "Host: evil.example" -H 'Host: evil.example' "${URL}/api/status"
expect H2 200 "Host: ${ALLOWED_HOST}" -H "Host: ${ALLOWED_HOST}:${PORT}" "${URL}/api/status"
expect H2-localhost 200 "Host: localhost" -H "Host: localhost:${PORT}" "${URL}/api/status"
expect H2-ip 200 "Host: 127.0.0.1 (IP literal)" "${URL}/api/status"

# =============================================================================
step "A: include_acked behind the ack key"
expect A1 401 "include_acked=true without a key" "${URL}/api/findings?include_acked=true"
expect A2 200 "include_acked=true with the ack key" -H "X-API-Key: ${ACK_KEY}" "${URL}/api/findings?include_acked=true"
expect A3 200 "plain /api/findings without a key" "${URL}/api/findings"

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The OTLP span budget, Host allow-list and include_acked gate of ${IMAGE}."
  echo ""
  echo "| assertion | result |"
  echo "|---|---|"
  for row in "${SUMMARY[@]}"; do
    printf "| %s | %s |\n" "${row%%|*}" "${row#*|}"
  done
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
