#!/usr/bin/env bash
# config-fragments: the 0.9.25 `.perf-sentinel.d/` loader, and the deprecations
# that ride with it.
#
# Configuration can now be split into deterministic fragments loaded by
# priority, with the main `.perf-sentinel.toml` last. Two behaviours changed at
# the same time and both are gates, not conveniences: an invalid discovered file
# now stops with exit code 75 instead of discarding the valid files around it
# and continuing on defaults, and that rule now covers the implicit main file
# too, which used to warn and carry on.
#
# Assertions (see README.md):
#   A  two fragments merge recursively. The higher priority wins per key, and a
#      key only the lower one sets survives.
#   B  the main `.perf-sentinel.toml` loads last and beats every fragment.
#   C  a duplicate priority and a non-conforming name are both rejected.
#   D  a non-TOML file in the directory is ignored, not an error.
#   E  an invalid fragment exits 75: no silent fallback to defaults.
#   F  an invalid IMPLICIT main file exits 75 too (this is the changed one).
#   G  with `--config path/custom.toml`, fragments come from
#      `path/.perf-sentinel.d/` and NOT from the working directory.
#   H  the six reference GreenOps fragments load together, and
#      `60-daemon-docker.toml` loads as a standalone main config.
#   I  the three deprecated `[green]` keys warn and are ignored: the carbon
#      total is unchanged by `include_network_transport = false`, and a zeroed
#      embodied coefficient falls back to the default instead of erasing M.
#   J  `detection_config` is stamped on the report, and a report without it
#      still loads.
#   K  an absent carbon figure names its OWN cause: green off with a live
#      Electricity Maps scraper says so, zero traces says so, and the combined
#      wording is gone.
#   L  batch analysis warns once for all eight daemon-only GreenOps sections.
#      Daemon mode, green off, and no configured backend stay silent.
#
# I, J and K are not about fragments. They are here because they are the other
# half of what a 0.9.25 config load does differently: which coefficients still
# apply, what the run leaves on its own report, and what an absent figure is
# allowed to claim. A lab config carrying the deprecated keys would otherwise
# surface as unexplained warning noise in some other scenario's stderr.
#
# Self-contained: no cluster, no Docker, no daemon. Needs the local release
# binary, python3, and the product checkout for its `examples/` fragments (leg H
# SKIPs without it).
set -uo pipefail

SCENARIO="config-fragments"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# Any committed native fixture works: this scenario reads the loaded
# configuration back out of the report, it does not care what was analyzed.
FIXTURE="${LAB_ROOT}/scenarios/sql-backtick-redaction/fixtures/backtick.native.json"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
EXAMPLES="${PERF_SENTINEL_REPO_PATH}/examples"
# The exit code the product reserves for a configuration it will not guess at.
EXIT_TOOLING_ERROR=75

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
DAEMON_PID=""
cleanup() { [ -z "${DAEMON_PID}" ] || kill "${DAEMON_PID}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
die()  { color_red   "    error: $*"; exit 1; }

RESULTS=()
FAILS=0
assert_pass() { RESULTS+=("$1|PASS|$2"); color_green "    PASS $1: $2"; }
assert_fail() { RESULTS+=("$1|FAIL|$2"); color_red   "    FAIL $1: $2"; FAILS=$((FAILS + 1)); }
assert_skip() { RESULTS+=("$1|SKIP|$2"); color_red   "    SKIP $1: $2"; }

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
[ -f "${FIXTURE}" ] || die "missing fixture ${FIXTURE}"
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
step "binary ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"

# Run analyze from inside a case directory and record its exit code. The loaded
# configuration comes back in `detection_config`, which 0.9.25 stamps onto every
# report from the run that produced it, so the assertions read what the binary
# actually applied, not what the files said.
run_case() {  # $1 = case dir, rest = extra analyze flags
  local dir="$1"; shift
  ( cd "${dir}" && "${PERF_SENTINEL_LOCAL_BIN}" analyze "$@" \
      --input "${FIXTURE}" --format json > out.json 2> out.err )
  echo $?
}

threshold_of() {  # $1 = case dir, $2 = key in detection_config
  python3 -c "
import json, sys
try:
    print(json.load(open('$1/out.json'))['detection_config']['$2'])
except Exception:
    print('MISSING')"
}

mkcase() {  # $1 = name -> prints the dir, with a fragment directory ready
  local d="${TMP_DIR}/$1"
  rm -rf "${d}"
  mkdir -p "${d}/.perf-sentinel.d"
  echo "${d}"
}

step "A: fragments merge recursively, higher priority wins per key"
A="$(mkcase a)"
cat > "${A}/.perf-sentinel.d/10-base.toml" <<'EOF'
[detection]
n_plus_one_min_occurrences = 3
window_duration_ms = 700
EOF
cat > "${A}/.perf-sentinel.d/20-override.toml" <<'EOF'
[detection]
n_plus_one_min_occurrences = 9
EOF
A_RC="$(run_case "${A}")"
A_N1="$(threshold_of "${A}" n_plus_one_threshold)"
A_WIN="$(threshold_of "${A}" window_ms)"
if [ "${A_RC}" = "0" ] && [ "${A_N1}" = "9" ] && [ "${A_WIN}" = "700" ]; then
  assert_pass "A" "20- wins on the shared key (n+1=9) while 10-'s own key survives (window=700ms)"
else
  assert_fail "A" "rc=${A_RC}, n+1=${A_N1} (want 9), window=${A_WIN} (want 700)"
fi

# --- B: the main file loads last --------------------------------------------
step "B: .perf-sentinel.toml loads last and beats every fragment"
B="$(mkcase b)"
printf '[detection]\nn_plus_one_min_occurrences = 9\n' > "${B}/.perf-sentinel.d/90-frag.toml"
printf '[detection]\nn_plus_one_min_occurrences = 4\n' > "${B}/.perf-sentinel.toml"
B_RC="$(run_case "${B}")"
B_N1="$(threshold_of "${B}" n_plus_one_threshold)"
if [ "${B_RC}" = "0" ] && [ "${B_N1}" = "4" ]; then
  assert_pass "B" "the main file wins over priority 90 (n+1=4, not 9)"
else
  assert_fail "B" "rc=${B_RC}, n+1=${B_N1} (want 4)"
fi

# --- C: rejected names ------------------------------------------------------
step "C: duplicate priority and non-conforming name are rejected"
C1="$(mkcase c1)"
printf '[detection]\nn_plus_one_min_occurrences = 9\n' > "${C1}/.perf-sentinel.d/10-a.toml"
printf '[detection]\nn_plus_one_min_occurrences = 8\n' > "${C1}/.perf-sentinel.d/10-b.toml"
C1_RC="$(run_case "${C1}")"
C2="$(mkcase c2)"
printf '[detection]\nn_plus_one_min_occurrences = 9\n' > "${C2}/.perf-sentinel.d/10-Upper.toml"
C2_RC="$(run_case "${C2}")"
C1_MSG="$(grep -o 'duplicate fragment priority.*' "${C1}/out.err" | head -1)"
C2_MSG="$(grep -o 'invalid fragment name.*' "${C2}/out.err" | head -1)"
if [ "${C1_RC}" = "${EXIT_TOOLING_ERROR}" ] && [ "${C2_RC}" = "${EXIT_TOOLING_ERROR}" ] \
   && [ -n "${C1_MSG}" ] && [ -n "${C2_MSG}" ]; then
  assert_pass "C" "both exit ${EXIT_TOOLING_ERROR} and name the offender: ${C1_MSG}"
else
  assert_fail "C" "duplicate rc=${C1_RC}, uppercase rc=${C2_RC} (want ${EXIT_TOOLING_ERROR} both); msgs: [${C1_MSG}] [${C2_MSG}]"
fi

step "D: a non-TOML file in the fragment directory is ignored"
D="$(mkcase d)"
printf '[detection]\nn_plus_one_min_occurrences = 7\n' > "${D}/.perf-sentinel.d/10-ok.toml"
printf 'this is not toml {{{ and never will be\n' > "${D}/.perf-sentinel.d/notes.txt"
D_RC="$(run_case "${D}")"
D_N1="$(threshold_of "${D}" n_plus_one_threshold)"
if [ "${D_RC}" = "0" ] && [ "${D_N1}" = "7" ]; then
  assert_pass "D" "notes.txt ignored, the valid fragment still applied (n+1=7)"
else
  assert_fail "D" "rc=${D_RC} (want 0), n+1=${D_N1} (want 7)"
fi

# --- E: an invalid fragment stops the command -------------------------------
step "E: an invalid fragment exits ${EXIT_TOOLING_ERROR}, no fallback to defaults"
E="$(mkcase e)"
printf '[detection]\nn_plus_one_min_occurrences = 7\n' > "${E}/.perf-sentinel.d/10-ok.toml"
printf '[detection\nn_plus_one_min_occurrences =\n' > "${E}/.perf-sentinel.d/20-bad.toml"
E_RC="$(run_case "${E}")"
# Match the file name, not the wording around it: 0.9.25 dropped the "config
# fragment <name>" phrasing on purpose (the main .perf-sentinel.toml travels
# the same loader and is not a fragment, product commit 83be3d84). The
# contract is that the error names the offending file, which it still does.
E_MSG="$(grep -o '20-bad\.toml.*' "${E}/out.err" | head -1 | cut -c1-90)"
if [ "${E_RC}" = "${EXIT_TOOLING_ERROR}" ] && [ -n "${E_MSG}" ] && [ ! -s "${E}/out.json" ]; then
  assert_pass "E" "exit ${EXIT_TOOLING_ERROR}, no report written, error names the fragment: ${E_MSG}"
else
  assert_fail "E" "rc=${E_RC} (want ${EXIT_TOOLING_ERROR}), report bytes=$(wc -c < "${E}/out.json" | tr -d ' '), msg=[${E_MSG}]"
fi

# --- F: the implicit main file follows the same rule ------------------------
step "F: an invalid IMPLICIT .perf-sentinel.toml exits ${EXIT_TOOLING_ERROR} (changed in 0.9.25)"
F="${TMP_DIR}/f"; rm -rf "${F}"; mkdir -p "${F}"
printf '[detection\nbroken =\n' > "${F}/.perf-sentinel.toml"
F_RC="$(run_case "${F}")"
F_MSG="$(grep -o '\.perf-sentinel\.toml.*' "${F}/out.err" | head -1 | cut -c1-90)"
if [ "${F_RC}" = "${EXIT_TOOLING_ERROR}" ] && [ ! -s "${F}/out.json" ]; then
  assert_pass "F" "exit ${EXIT_TOOLING_ERROR} rather than warning and running on defaults: ${F_MSG}"
else
  assert_fail "F" "rc=${F_RC} (want ${EXIT_TOOLING_ERROR}), report bytes=$(wc -c < "${F}/out.json" | tr -d ' ')"
fi

# --- G: --config relocates the fragment directory ---------------------------
step "G: --config reads fragments beside it, not from the working directory"
G="${TMP_DIR}/g"; rm -rf "${G}"; mkdir -p "${G}/conf/.perf-sentinel.d" "${G}/work/.perf-sentinel.d"
printf '[detection]\nn_plus_one_min_occurrences = 9\nwindow_duration_ms = 800\n' \
  > "${G}/conf/.perf-sentinel.d/10-frag.toml"
printf '[detection]\nn_plus_one_min_occurrences = 6\n' > "${G}/conf/custom.toml"
# The decoy: a fragment in the working directory that must NOT be read.
printf '[detection]\nn_plus_one_min_occurrences = 99\nwindow_duration_ms = 111\n' \
  > "${G}/work/.perf-sentinel.d/10-cwd.toml"
G_RC="$(run_case "${G}/work" --config "${G}/conf/custom.toml")"
G_N1="$(threshold_of "${G}/work" n_plus_one_threshold)"
G_WIN="$(threshold_of "${G}/work" window_ms)"
if [ "${G_RC}" = "0" ] && [ "${G_N1}" = "6" ] && [ "${G_WIN}" = "800" ]; then
  assert_pass "G" "custom.toml last (n+1=6), its sibling fragment applied (window=800ms), the cwd decoy ignored"
else
  assert_fail "G" "rc=${G_RC}, n+1=${G_N1} (want 6, 99 would mean the cwd was read), window=${G_WIN} (want 800)"
fi

step "H: the six reference GreenOps fragments load together"
REF_FRAGMENTS="30-green-alumet 31-green-cloud 32-green-scaphandre 33-green-kepler 34-green-redfish 40-green-electricity-maps"
if [ -d "${EXAMPLES}" ]; then
  H="$(mkcase h)"
  MISSING=""
  for f in ${REF_FRAGMENTS}; do
    cp "${EXAMPLES}/${f}.toml" "${H}/.perf-sentinel.d/" 2>/dev/null || MISSING="${MISSING} ${f}"
  done
  H_RC="$(run_case "${H}")"
  H2="${TMP_DIR}/h2"; rm -rf "${H2}"; mkdir -p "${H2}"
  cp "${EXAMPLES}/60-daemon-docker.toml" "${H2}/.perf-sentinel.toml" 2>/dev/null \
    && H2_RC="$(run_case "${H2}")" || H2_RC="missing"
  if [ -z "${MISSING}" ] && [ "${H_RC}" = "0" ] && [ "${H2_RC}" = "0" ]; then
    assert_pass "H" "all six fragments load together, and 60-daemon-docker.toml loads as a standalone main config"
  else
    assert_fail "H" "missing:${MISSING:- none}, six-fragment rc=${H_RC}, 60-daemon-docker rc=${H2_RC}"
  fi
else
  assert_skip "H" "no product checkout at ${EXAMPLES}"
fi

step "I: the deprecated [green] keys warn, and changing them changes nothing"
I_OFF="${TMP_DIR}/i-off"; rm -rf "${I_OFF}"; mkdir -p "${I_OFF}"
I_REF="${TMP_DIR}/i-ref"; rm -rf "${I_REF}"; mkdir -p "${I_REF}"
cat > "${I_OFF}/.perf-sentinel.toml" <<'EOF'
[green]
enabled = true
default_region = "FR"
include_network_transport = false
network_energy_per_byte_kwh = 0.0
embodied_carbon_per_request_gco2 = 0.0
EOF
cat > "${I_REF}/.perf-sentinel.toml" <<'EOF'
[green]
enabled = true
default_region = "FR"
EOF
I_OFF_RC="$(run_case "${I_OFF}")"
I_REF_RC="$(run_case "${I_REF}")"
I_WARNS="$(grep -c "deprecated\|no longer honoured" "${I_OFF}/out.err" 2>/dev/null || echo 0)"
# The point of 2.1: a setting that used to remove a term from the published
# figure is ignored, so the two totals must be byte-identical.
I_SAME="$(python3 -c "
import json
def co2(p):
    return (json.load(open(p))['green_summary'] or {}).get('co2', {}).get('total', {})
a, b = co2('${I_OFF}/out.json'), co2('${I_REF}/out.json')
print(1 if a and a == b else 0)
print(a.get('methodology', ''))" 2>/dev/null | head -1)"
I_METH="$(python3 -c "
import json
print((json.load(open('${I_OFF}/out.json'))['green_summary'] or {}).get('co2', {}).get('total', {}).get('methodology', ''))" 2>/dev/null)"
if [ "${I_OFF_RC}" = "0" ] && [ "${I_REF_RC}" = "0" ] && [ "${I_WARNS}" -ge 3 ] \
   && [ "${I_SAME}" = "1" ] && [[ "${I_METH}" == *transport* ]]; then
  assert_pass "I" "${I_WARNS} deprecation warnings, both runs load, identical carbon total, methodology still '${I_METH}'"
else
  assert_fail "I" "rc=${I_OFF_RC}/${I_REF_RC}, warnings=${I_WARNS} (want >=3), totals identical=${I_SAME}, methodology=${I_METH}"
fi

# --- J: detection_config is additive ----------------------------------------
# Every leg above reads the loaded configuration back out of `detection_config`,
# which is itself new in 0.9.25. This leg closes the other side of that: a report
# from a binary that had no such field must still load. The baseline is built by
# deleting the key, which is exactly the shape a 0.9.24 report has.
step "J: detection_config is present, and a report without it still loads"
J="${TMP_DIR}/j"; rm -rf "${J}"; mkdir -p "${J}"
J_RC="$(run_case "${J}")"
python3 -c "
import json
d = json.load(open('${J}/out.json'))
d.pop('detection_config', None)
json.dump(d, open('${J}/pre-0925.json', 'w'))"
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${J}/pre-0925.json" --output "${J}/pre-0925.html" \
  > "${J}/report.log" 2>&1
J_REPORT_RC=$?
J_KEYS="$(python3 -c "
import json
print(len(json.load(open('${J}/out.json')).get('detection_config') or {}))" 2>/dev/null)"
if [ "${J_RC}" = "0" ] && [ "${J_KEYS}" -ge 8 ] && [ "${J_REPORT_RC}" = "0" ] && [ -s "${J}/pre-0925.html" ]; then
  assert_pass "J" "${J_KEYS} detection settings stamped on the report, and a report without the block still renders ($(wc -c < "${J}/pre-0925.html" | tr -d ' ') bytes)"
else
  assert_fail "J" "analyze rc=${J_RC}, detection_config keys=${J_KEYS} (want >=8), report rc=${J_REPORT_RC}"
fi

# --- K: an absent carbon figure names its real cause ------------------------
# 0.9.25 prints absent figures greyed out with their cause instead of omitting
# them. The first version of that deduced the cause from the presence of
# `scoring_config`, which is not a signal that GreenOps ran: the daemon stamps
# that object as soon as Electricity Maps is configured, `[green] enabled`
# notwithstanding. A daemon in that configuration having processed thousands of
# traces therefore claimed "no traces analyzed" on a busy window.
#
# So the leg runs the combination that revealed it, green off WITH an
# electricity_maps block, which is legitimate since the scraper runs
# independently of the toggle, and the honest zero-trace case, and asserts each
# names its own cause. The combined "enabled = false, or no traces analyzed"
# wording no longer exists.
step "K: an absent carbon figure names its own cause, on both paths"
K_OFF="${TMP_DIR}/k-off"; rm -rf "${K_OFF}"; mkdir -p "${K_OFF}"
K_EMPTY="${TMP_DIR}/k-empty"; rm -rf "${K_EMPTY}"; mkdir -p "${K_EMPTY}"
cat > "${K_OFF}/.perf-sentinel.toml" <<'EOF'
[green]
enabled = false
default_region = "FR"

[green.electricity_maps]
api_key = "lab-placeholder"
region_map = { "eu-west-3" = "FR" }
EOF
cat > "${K_EMPTY}/.perf-sentinel.toml" <<'EOF'
[green]
enabled = true
default_region = "FR"
EOF
echo '[]' > "${K_EMPTY}/no-spans.json"
( cd "${K_OFF}" && "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIXTURE}" > out.txt 2> out.err )
( cd "${K_EMPTY}" && "${PERF_SENTINEL_LOCAL_BIN}" analyze --input no-spans.json > out.txt 2> out.err )
K_OFF_LINE="$(grep -a "Carbon:" "${K_OFF}/out.txt" | head -1 | sed 's/^ *//')"
K_EMPTY_LINE="$(grep -a "Carbon:" "${K_EMPTY}/out.txt" | head -1 | sed 's/^ *//')"
if [[ "${K_OFF_LINE}" == *"enabled = false"* ]] && [[ "${K_OFF_LINE}" != *"no traces analyzed"* ]] \
   && [[ "${K_EMPTY_LINE}" == *"no traces analyzed"* ]] && [[ "${K_EMPTY_LINE}" != *"enabled = false"* ]]; then
  assert_pass "K" "green off with a live scraper says '${K_OFF_LINE#*not computed }', zero traces says '${K_EMPTY_LINE#*not computed }' — no combined wording left"
else
  assert_fail "K" "green-off line: [${K_OFF_LINE:-<none>}]; zero-trace line: [${K_EMPTY_LINE:-<none>}]"
fi

# --- L: batch-only backend warning -----------------------------------------
step "L: all daemon-only GreenOps sections warn in batch mode only"
L_ALL="$(mkcase l-all)"
cat > "${L_ALL}/.perf-sentinel.toml" <<'EOF'
[green]
enabled = true
default_region = "eu-west-3"

[green.alumet]
endpoint = "http://127.0.0.1:1/metrics"
metric_name = "attributed_energy_cpu_alumet"
label_key = "name"

[green.scaphandre]
endpoint = "http://127.0.0.1:1/metrics"

[green.kepler]
endpoint = "http://127.0.0.1:1/metrics"

[green.redfish.endpoints.lab]
url = "https://127.0.0.1:1/redfish/v1/Chassis/1/Power"
schema = "legacy_power"

[green.cloud]
prometheus_endpoint = "http://127.0.0.1:1"
default_provider = "aws"
default_instance_type = "c5.4xlarge"

[green.database_static]
placement = "dedicated"
nodes = 2
instance_type = "db.r6i.large"

[green.broker_static]
placement = "dedicated"
nodes = 1
provider = "aws"
instance_type = "m5.2xlarge"

[green.electricity_maps]
api_key = "lab-placeholder"
region_map = { "eu-west-3" = "FR" }
EOF
L_ALL_RC="$(run_case "${L_ALL}")"

L_OFF="$(mkcase l-off)"
cat > "${L_OFF}/.perf-sentinel.toml" <<'EOF'
[green]
enabled = false
[green.scaphandre]
endpoint = "http://127.0.0.1:1/metrics"
EOF
L_OFF_RC="$(run_case "${L_OFF}")"
L_NONE="$(mkcase l-none)"
L_NONE_RC="$(run_case "${L_NONE}")"

read -r L_HTTP L_GRPC < <(python3 - <<'PY'
import socket
ports = []
for _ in range(2):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    ports.append(sock.getsockname()[1])
    sock.close()
print(*ports)
PY
)
L_DAEMON="${TMP_DIR}/l-daemon"
mkdir -p "${L_DAEMON}"
cat > "${L_DAEMON}/config.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${L_HTTP}
listen_port_grpc = ${L_GRPC}
api_enabled = true
trace_ttl_ms = 1000

[daemon.ack]
enabled = false

[green]
enabled = true
[green.scaphandre]
endpoint = "http://127.0.0.1:1/metrics"
EOF
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${L_DAEMON}/config.toml" > "${L_DAEMON}/watch.log" 2>&1 &
DAEMON_PID=$!
L_DAEMON_RC=1
for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:${L_HTTP}/api/export/report" > "${L_DAEMON}/report.json" 2>/dev/null; then
    L_DAEMON_RC=0
    break
  fi
  kill -0 "${DAEMON_PID}" 2>/dev/null || break
  sleep 0.25
done
kill "${DAEMON_PID}" 2>/dev/null || true
wait "${DAEMON_PID}" 2>/dev/null || true
DAEMON_PID=""

if python3 - "${L_ALL}/out.json" "${L_OFF}/out.json" "${L_NONE}/out.json" "${L_DAEMON}/report.json" <<'PY'
import json, sys

all_report, off, none, daemon = (json.load(open(path)) for path in sys.argv[1:])
warnings = [w for w in all_report.get("warning_details", []) if "batch run" in w["message"]]
expected = {
    "[green.alumet]", "[green.scaphandre]", "[green.kepler]", "[green.redfish]",
    "[green.cloud]", "[green.database_static]", "[green.broker_static]",
    "[green.electricity_maps]",
}
assert len(warnings) == 1 and all(name in warnings[0]["message"] for name in expected)
for report in (off, none, daemon):
    assert not any("batch run" in w["message"] for w in report.get("warning_details", []))
PY
then
  if [ "${L_ALL_RC}" = "0" ] && [ "${L_OFF_RC}" = "0" ] && [ "${L_NONE_RC}" = "0" ] && [ "${L_DAEMON_RC}" = "0" ]; then
    assert_pass "L" "one batch warning names all eight sections; daemon, green-off and no-backend controls stay silent"
  else
    assert_fail "L" "commands rc all/off/none/daemon=${L_ALL_RC}/${L_OFF_RC}/${L_NONE_RC}/${L_DAEMON_RC}"
  fi
else
  assert_fail "L" "warning presence or one of the three negative controls is wrong"
fi

# --- verdict ----------------------------------------------------------------
step "Summary"
verdict="PASS"
[ "${FAILS}" -gt 0 ] && verdict="FAIL"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Binary: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo ""
  echo "| id | result | detail |"
  echo "|---|---|---|"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r id res msg <<< "${r}"
    echo "| ${id} | ${res} | ${msg} |"
  done
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
  exit 0
fi
color_red "FAIL (${FAILS}) — report at ${REPORT}"
exit 1
