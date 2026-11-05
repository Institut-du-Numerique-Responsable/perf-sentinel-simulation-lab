#!/usr/bin/env bash
# memory-guard-band-release: the 0.42.1 [daemon] memory_high_water_pct release,
# read from a real cgroup v2 limit on a throwaway container. `docker update`
# moves memory.max live, which places the working-set ratio above the mark,
# inside the hysteresis band or below it on demand.
#
# Assertions (see README.md):
#   I1  below the mark the gauge reads 0 and an OTLP export answers 200
#   C1  above the mark the gauge reads 1 within 5 seconds
#   C2  an OTLP export answers 503
#   C3  perf_sentinel_otlp_rejected_total{reason="memory_pressure"} grew by 1
#   P1  a ratio parked above the mark stays rejected past the hold, with no release warning
#   B1  a ratio parked inside the band releases after the 60-second hold
#   B2  the release warning fires once and names a ratio inside the band
#   B3  an OTLP export answers 200 again
#   R1  crossing the mark again sets the gauge
#   R2  falling below the resume mark clears the gauge within 5 seconds
#   R3  that recovery logs no release warning
#   O1  a ratio oscillating around the mark still releases
#   T1  with trace_ttl_ms = 90000 the hold lasts 90 seconds
#   T2  the warning of that release names 90s
#
# Needs Docker with cgroup v2, curl and python3. Takes about 9 minutes. The image
# resolves through scripts/resolve-image.sh.
set -uo pipefail

SCENARIO="memory-guard-band-release"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"
PORT="${PORT:-15441}"
NAME="mgb-daemon"
URL="http://127.0.0.1:${PORT}"
GAUGE="perf_sentinel_ingest_memory_pressure"
COUNTER='perf_sentinel_otlp_rejected_total{reason="memory_pressure"}'
WARNING="memory working set held at"
# Mark at 85, so the band runs from 80 to 85.
ABOVE=0.92
BAND=0.825
BELOW=0.70

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS: $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL: $2"; }
check() { # check <id> <description> <test args...>
  local id="$1" what="$2"
  shift 2
  if [ "$@" ]; then assert_pass "${id}" "${what}"; else assert_fail "${id}" "${what}"; fi
}

metric() {
  curl -fsS "${URL}/metrics" | awk -v m="$1" '$1 == m { printf "%.0f\n", $2; found=1 } END { if (!found) print 0 }'
}
gauge() { metric "${GAUGE}"; }
export_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/x-protobuf' \
    --data-binary "@${TMP_DIR}/small.pb" "${URL}/v1/traces"
}
warnings() { docker logs "${NAME}" 2>&1 | grep -c "${WARNING}"; }
# Working set in bytes: docker stats subtracts inactive_file, like the guard.
working_set() {
  docker stats --no-stream --format '{{.MemUsage}}' "${NAME}" | python3 -c '
import re, sys
value, unit = re.match(r"([0-9.]+)(\w+)", sys.stdin.read()).groups()
print(int(float(value) * {"B": 1, "KiB": 2**10, "MiB": 2**20, "GiB": 2**30}[unit]))'
}
limit_for() { python3 -c "print(int($1 / $2))"; }
set_limit() { docker update --memory "$1" --memory-swap "$1" "${NAME}" >/dev/null || die "docker update --memory $1 failed"; }
set_ratio() { set_limit "$(limit_for "$(working_set)" "$1")"; }
# wait_gauge <wanted> <timeout seconds>: prints the seconds waited, fails on timeout.
wait_gauge() {
  local start=${SECONDS}
  while [ $((SECONDS - start)) -le "$2" ]; do
    if [ "$(gauge)" = "$1" ]; then echo $((SECONDS - start)); return 0; fi
    sleep 1
  done
  echo $((SECONDS - start))
  return 1
}
# wait_gauge_pinned <wanted> <timeout seconds> <ratio>: wait_gauge, re-pinning the
# ratio every 5 seconds. On a 20 MiB working set one 2 MiB allocator step moves the
# ratio by 10 points, out of a 5-point band, and the guard then rightly keeps rejecting.
wait_gauge_pinned() {
  local start=${SECONDS} pinned=${SECONDS}
  while [ $((SECONDS - start)) -le "$2" ]; do
    if [ "$(gauge)" = "$1" ]; then echo $((SECONDS - start)); return 0; fi
    if [ $((SECONDS - pinned)) -ge 5 ]; then set_ratio "$3"; pinned=${SECONDS}; fi
    sleep 1
  done
  echo $((SECONDS - start))
  return 1
}
start_daemon() { # start_daemon <extra [daemon] lines>
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  cat > "${TMP_DIR}/config.toml" <<EOF
[daemon]
listen_address = "0.0.0.0"
memory_high_water_pct = 85
$1
EOF
  docker run -d --name "${NAME}" --memory 512m --memory-swap 512m \
    -v "${TMP_DIR}/config.toml:/etc/perf-sentinel/config.toml:ro" \
    -p "127.0.0.1:${PORT}:4318" \
    "${IMAGE}" watch -c /etc/perf-sentinel/config.toml >/dev/null || die "cannot start ${IMAGE}"
  for _ in $(seq 40); do curl -sf "${URL}/health" >/dev/null && break; sleep 0.5; done
  curl -sf "${URL}/health" >/dev/null || { docker logs "${NAME}" > "${TMP_DIR}/daemon.log" 2>&1; die "daemon never answered /health, see ${TMP_DIR}/daemon.log"; }
  # The allocator's first steps land in the first minute, and one of them under
  # the tight limit of the "above" leg could reach memory.max.
  sleep 60
}

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

command -v docker >/dev/null || die "docker not found"
command -v curl >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"
[ "$(docker info --format '{{.CgroupVersion}}')" = "2" ] || die "this scenario needs cgroup v2"
step "image under test: ${IMAGE}"

rm -rf "${TMP_DIR}" "${REPORT}"
mkdir -p "${TMP_DIR}"
cleanup

# Ten empty spans: field 2 of ScopeSpans, length 0.
python3 - "${TMP_DIR}" <<'PY'
import sys

def wrap(tag, inner):
    return bytes([tag, len(inner)]) + inner

open(f"{sys.argv[1]}/small.pb", "wb").write(wrap(0x0A, wrap(0x12, b"\x12\x00" * 10)))
PY

start_daemon ""
ok "daemon $(curl -fsS "${URL}/api/status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version"))'), working set $(working_set) bytes"

# =============================================================================
step "I: below the mark"
code="$(export_code)"
check I1 "gauge $(gauge), export ${code}" "$(gauge)-${code}" = "0-200"

# =============================================================================
step "C: crossing the mark"
BEFORE="$(metric "${COUNTER}")"
set_ratio "${ABOVE}"
waited="$(wait_gauge 1 5)"; check C1 "gauge 1 after ${waited}s" "$?" = "0"
code="$(export_code)"; check C2 "export answers ${code}" "${code}" = "503"
AFTER="$(metric "${COUNTER}")"
check C3 "${COUNTER} ${BEFORE} -> ${AFTER}" "$((AFTER - BEFORE))" = "1"

# =============================================================================
step "P: parked above the mark, past the hold"
released=0
for _ in $(seq 75); do [ "$(gauge)" = "1" ] || released=1; sleep 1; done
check P1 "gauge stayed 1 for 75s, ${released} release(s), $(warnings) warning(s)" "${released}-$(warnings)" = "0-0"

# =============================================================================
step "B: parked inside the band"
set_ratio "${BAND}"
waited="$(wait_gauge_pinned 0 90 "${BAND}")"; rc=$?
if [ "${rc}" = "0" ] && [ "${waited}" -ge 55 ] && [ "${waited}" -le 75 ]; then
  assert_pass B1 "released after ${waited}s"
else
  assert_fail B1 "gauge 0 after ${waited}s (rc ${rc}), wanted 55 to 75"
fi
line="$(docker logs "${NAME}" 2>&1 | grep "${WARNING}" | tail -1)"
ratio="$(printf '%s' "${line}" | sed -E 's/.*held at ([0-9.]+)%.*/\1/')"
if [ "$(warnings)" = "1" ] && python3 -c "import sys; sys.exit(0 if 80 <= float('${ratio:-0}') < 85 else 1)" 2>/dev/null; then
  assert_pass B2 "one warning, at ${ratio}%"
else
  assert_fail B2 "$(warnings) warning(s), ratio '${ratio}': ${line}"
fi
code="$(export_code)"; check B3 "export answers ${code}" "${code}" = "200"

# =============================================================================
step "R: a new crossing, then a normal recovery"
count="$(warnings)"
set_ratio "${ABOVE}"
waited="$(wait_gauge 1 5)"; check R1 "gauge 1 after ${waited}s" "$?" = "0"
set_ratio "${BELOW}"
waited="$(wait_gauge 0 5)"; check R2 "gauge 0 after ${waited}s" "$?" = "0"
check R3 "warnings ${count} -> $(warnings)" "$(warnings)" = "${count}"

# =============================================================================
step "O: oscillating around the mark"
count="$(warnings)"
WS="$(working_set)"
HIGH_LIMIT="$(limit_for "${WS}" 0.87)"
BAND_LIMIT="$(limit_for "${WS}" 0.83)"
start=${SECONDS}
while [ "$(warnings)" = "${count}" ] && [ $((SECONDS - start)) -le 170 ]; do
  set_limit "${HIGH_LIMIT}"; sleep 5
  [ "$(warnings)" = "${count}" ] || break
  set_limit "${BAND_LIMIT}"; sleep 5
done
check O1 "released while oscillating after $((SECONDS - start))s, warnings ${count} -> $(warnings)" "$(warnings)" != "${count}"

# =============================================================================
step "T: trace_ttl_ms longer than the shortest hold"
start_daemon "trace_ttl_ms = 90000"
set_ratio "${ABOVE}"
wait_gauge 1 5 >/dev/null || die "gauge never reached 1 on the second daemon"
set_ratio "${BAND}"
waited="$(wait_gauge_pinned 0 120 "${BAND}")"; rc=$?
if [ "${rc}" = "0" ] && [ "${waited}" -ge 85 ] && [ "${waited}" -le 105 ]; then
  assert_pass T1 "released after ${waited}s"
else
  assert_fail T1 "gauge 0 after ${waited}s (rc ${rc}), wanted 85 to 105"
fi
line="$(docker logs "${NAME}" 2>&1 | grep "${WARNING}" | tail -1)"
case "${line}" in
  *"for 90s"*) assert_pass T2 "warning names 90s" ;;
  *) assert_fail T2 "warning: ${line}" ;;
esac

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The memory guard's band release on a real cgroup v2 limit, with ${IMAGE}."
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
  color_green "PASS, report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)), report at ${REPORT}"
fi
