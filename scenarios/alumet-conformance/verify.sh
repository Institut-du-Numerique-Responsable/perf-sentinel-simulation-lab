#!/usr/bin/env bash
# alumet-conformance: validate perf-sentinel 0.9.12's Alumet measured-energy
# backend against the REAL alumet-agent (v0.9.5, upstream .deb) and a frozen
# capture of its exposition. Pre-validates the product CI job
# `alumet-wire-conformance` by replaying its steps, then goes further with the
# legs only a deterministic wire file allows: summed-label energy math, desync
# scaling, precedence over Scaphandre, warn latches, /api/energy shape.
# Self-contained: local release binary. Docker is needed only for the live
# legs (A/B/C) and they SKIP cleanly without it. No cluster.
#
# Assertions (see README.md):
#   A   wire capture of the real agent exposition (artifact -> /tmp copy).
#   B   wire shape: `_alumet` suffix + resource_consumer_kind="process" rows +
#       the CI job's verbatim dynamic metric-name discovery yields a name.
#   C   daemon e2e vs the live agent: scraper started, both warn markers
#       absent, success counter increments, freshness gauge stays low.
#   D   summed-label math on the frozen capture: per_service_energy_kwh ==
#       sum(positive process rows) * scrape_interval / (energy_interval *
#       3.6e6) within 1% -- every row sharing the label value must be summed.
#   E   desync: energy_interval_secs=5.0 vs 1.0 -> exactly x5 (silent linear
#       rescale documented in LIMITATIONS.md#alumet-precision-bounds).
#   F   precedence: Alumet + Scaphandre both mapped on the same service ->
#       per_service_energy_model says alumet_rapl.
#   G1  mistyped mapping -> the no-match warn latches ONCE after 3 ticks while
#       scraping stays healthy.  G2 empty service_mappings -> startup warn
#       once, never recurring.  G3 /api/energy: 16 rows (7 energy backends, Electricity
#       Maps, 8 grid operator feeds), alumet FIRST.
#
# Wire gotchas locked by the 2026-07-16 capture (see fixtures/):
#   - the .deb ships /etc/alumet/alumet-config.toml WITHOUT a
#     prometheus-exporter section, but enabling the exporter still works:
#     the agent backfills the absent section from the plugin's defaults.
#     We point ALUMET_CONFIG at a fresh path only to capture against a
#     clean, minimal config (prefix "", suffix "_alumet", port 9091).
#   - the packaged binary carries file capabilities
#     (cap_sys_ptrace,cap_sys_nice,cap_perfmon=ep): inside docker the exec
#     fails with EPERM unless those caps are added to the container.
#   - upstream's unit-suffix branch is inverted: unit-carrying metrics LOSE
#     the unit (kernel_cpu_time_alumet) and unitless ones gain a trailing
#     underscore (kernel_context_switches_alumet_). Names are therefore always
#     discovered from the wire, never hardcoded.
set -uo pipefail

SCENARIO="alumet-conformance"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
DD_FIX="${SCRIPT_DIR}/../datadog-bridge/fixtures"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}/mock"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14498}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14499}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
AGENT_PORT="${AGENT_PORT:-19091}"
MOCK_PORT="${MOCK_PORT:-19092}"
ALUMET_VERSION="${ALUMET_VERSION:-v0.9.5}"
# Pinned per arch: refresh deliberately if upstream republishes the tag.
ALUMET_DEB_SHA256_ARM64="${ALUMET_DEB_SHA256_ARM64:-f7c3b11fcd3d0c66cb1f13527dd9dd284b3c348f9cc4fd5a2276e657a17ba0d7}"
ALUMET_DEB_SHA256_AMD64="${ALUMET_DEB_SHA256_AMD64:-1ce5ff9a43619e4023c247623622c6e1d5e44e8e511e9505d04254d9043f0c68}"
DEB_CACHE_DIR="${DEB_CACHE_DIR:-/tmp/alumet-deb-cache}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
SUMMARY=()
NOTES=()
record() { SUMMARY+=("$1|$2"); }                 # assertion-id | result text
note()   { NOTES+=("$1"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }
record_skip() { skip "$2"; record "$1" "SKIP — $2"; }

DAEMON_PID=""
MOCK_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  [ -n "${MOCK_PID}" ] && kill "${MOCK_PID}" 2>/dev/null || true
  docker rm -f "alumet-wire" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -s "${FIX}/alumet-wire-capture.prom" ] || die "committed fixture ${FIX}/alumet-wire-capture.prom missing"
[ -s "${DD_FIX}/dd-bridge-nplusone.pb" ] || die "trace fixture ${DD_FIX}/dd-bridge-nplusone.pb missing"

# ── helpers ─────────────────────────────────────────────────────────────────
free_daemon_port() {
  pkill -f "perf-sentinel watch.*${TMP_DIR}/daemon-" 2>/dev/null || true
  for p in "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}"; do
    lsof -ti "tcp:${p}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  done
}

start_daemon() {  # $1 = config file under TMP_DIR ; $2 = log file under TMP_DIR
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  free_daemon_port
  sleep 1
  RUST_LOG=info "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/$1" > "${TMP_DIR}/$2" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

stop_daemon() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  wait "${DAEMON_PID}" 2>/dev/null || true
  DAEMON_PID=""
}

post_traces() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"${DD_FIX}/dd-bridge-nplusone.pb"
}

# Pick the `_alumet`-suffixed metric with the most finite-positive rows carrying
# resource_consumer_kind="process" (never hardcode a name: the upstream
# unit-suffix branch decides the exact spelling).
discover_metric() {  # $1 = exposition file
  python3 - "$1" <<'EOF'
import re, sys, collections
counts = collections.Counter()
for line in open(sys.argv[1]):
    if line.startswith('#'): continue
    m = re.match(r'^([a-zA-Z_:][a-zA-Z0-9_:]*_alumet)\{(.*)\}\s+(\S+)', line)
    if not m: continue
    name, labels, val = m.groups()
    try: v = float(val)
    except ValueError: continue
    if 'resource_consumer_kind="process"' in labels and v > 0 and v == v and v != float('inf'):
        counts[name] += 1
print(counts.most_common(1)[0][0] if counts else "")
EOF
}

# Sum of finite-positive rows of $2 carrying resource_consumer_kind="process",
# mirroring the daemon's per-row filter. Prints "sum rows".
wire_joules_sum() {  # $1 = exposition file, $2 = metric name
  python3 - "$1" "$2" <<'EOF'
import re, sys
total, rows = 0.0, 0
name = re.escape(sys.argv[2])
pat = re.compile(r'^' + name + r'\{(.*)\}\s+(\S+)')
for line in open(sys.argv[1]):
    m = pat.match(line)
    if not m: continue
    labels, val = m.groups()
    try: v = float(val)
    except ValueError: continue
    if 'resource_consumer_kind="process"' in labels and v > 0 and v == v and v != float('inf'):
        total += v; rows += 1
print(f"{total!r} {rows}")
EOF
}

alumet_success_count() {  # reads the daemon's own /metrics
  curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null | awk '
    index($0,"perf_sentinel_alumet_scrape_total")==1 && index($0,"status=\"success\"")>0 {print int($2); found=1; exit}
    END {if(!found) print 0}'
}

alumet_failed_count() {  # sums every reason child
  curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null | awk '
    index($0,"perf_sentinel_alumet_scrape_failed_total{")==1 {s+=$2}
    END {print int(s)}'
}

alumet_freshness() {
  curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null | awk '
    index($0,"perf_sentinel_alumet_last_scrape_age_seconds")==1 && $0 !~ /^#/ {print $2; found=1; exit}
    END {if(!found) print 9999}'
}

# Extract "model|kwh" for a service from /api/export/report's green_summary.
report_energy_for() {  # $1 = service ; reads stdin
  python3 -c '
import sys, json
svc = sys.argv[1]
gs = json.load(sys.stdin).get("green_summary") or {}
m = (gs.get("per_service_energy_model") or {}).get(svc, "")
k = (gs.get("per_service_energy_kwh") or {}).get(svc, "")
print(f"{m}|{k}")
' "$1"
}

# Seed the loopback daemon until per_service_energy_model reports a measured
# alumet coefficient (<=6 POSTs, 8s spacing: at most one batch per 5s scrape
# window, coefficient age <=13s < the 15s staleness cutoff).
seed_until_measured() {  # $1 = service ; sets SEED_MODEL / SEED_KWH
  SEED_MODEL=""; SEED_KWH=""
  for _ in $(seq 1 6); do
    local code
    code="$(post_traces)"
    [ "${code}" = "200" ] || { note "trace POST returned ${code}"; return 1; }
    sleep 4
    local out
    out="$(curl -fsS "${DAEMON_URL}/api/export/report" 2>/dev/null | report_energy_for "$1")"
    SEED_MODEL="${out%%|*}"; SEED_KWH="${out#*|}"
    [ "${SEED_MODEL}" = "alumet_rapl" ] && return 0
    sleep 4
  done
  return 1
}

daemon_header() {  # $1 = extra [green] root? "green" to enable carbon scoring
  cat <<EOF
$([ "${1:-}" = "green" ] && printf '[green]\nenabled = true\ndefault_region = "eu-west-3"\n')
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
trace_ttl_ms = 2000
environment = "staging"

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
EOF
}

# =============================================================================
# Preflight for the live legs: Docker + the pinned upstream .deb
# =============================================================================
step "Preflight: Docker + upstream alumet-agent .deb (${ALUMET_VERSION})"
HAVE_AGENT=0
AGENT_SKIP_REASON=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  case "$(uname -m)" in
    arm64|aarch64) DEB_ARCH="arm64"; DEB_SHA256="${ALUMET_DEB_SHA256_ARM64}" ;;
    *)             DEB_ARCH="amd64"; DEB_SHA256="${ALUMET_DEB_SHA256_AMD64}" ;;
  esac
  DEB_NAME="alumet-agent_${ALUMET_VERSION#v}-1_${DEB_ARCH}_ubuntu_24.04.deb"
  DEB_PATH="${DEB_CACHE_DIR}/${DEB_NAME}"
  mkdir -p "${DEB_CACHE_DIR}"
  if ! echo "${DEB_SHA256}  ${DEB_PATH}" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fsSL --max-time 120 -o "${DEB_PATH}" \
      "https://github.com/alumet-dev/alumet/releases/download/${ALUMET_VERSION}/${DEB_NAME}" \
      || AGENT_SKIP_REASON="deb download failed (network)"
  fi
  if [ -z "${AGENT_SKIP_REASON}" ]; then
    if echo "${DEB_SHA256}  ${DEB_PATH}" | shasum -a 256 -c - >/dev/null 2>&1; then
      HAVE_AGENT=1
      ok "deb cached and pinned (${DEB_ARCH})"
    else
      AGENT_SKIP_REASON="deb sha256 mismatch (upstream republished? refresh the pin deliberately)"
    fi
  fi
else
  AGENT_SKIP_REASON="Docker unavailable"
fi
[ "${HAVE_AGENT}" = "1" ] || skip "live legs will SKIP: ${AGENT_SKIP_REASON}"

# =============================================================================
# A + B: live wire capture and shape (real agent in docker)
# =============================================================================
LIVE_METRIC=""
if [ "${HAVE_AGENT}" = "1" ]; then
  step "Live agent: capture (A) + wire shape and discovery (B)"
  docker rm -f alumet-wire >/dev/null 2>&1 || true
  # Caps: the packaged binary carries file capabilities, without them exec
  # fails EPERM inside docker. Fresh ALUMET_CONFIG = a clean generated config;
  # an absent prometheus-exporter section is backfilled from defaults anyway.
  docker run -d --name alumet-wire --cpus=2 \
    --cap-add SYS_PTRACE --cap-add SYS_NICE --cap-add PERFMON \
    -p "127.0.0.1:${AGENT_PORT}:9091" \
    -e ALUMET_CONFIG=/var/lib/alumet-lab/alumet-config.toml \
    -v "${DEB_PATH}:/alumet.deb:ro" \
    ubuntu:24.04 bash -c '
      apt-get update -qq && apt-get install -yqq /alumet.deb ;
      mkdir -p /var/lib/alumet-lab ;
      for i in 1 2 3 4; do sh -c "while :; do :; done" & done ;
      exec alumet-agent --plugins procfs,prometheus-exporter \
        --config-override "plugins.prometheus-exporter.host=\"0.0.0.0\"" run' >/dev/null

  AGENT_UP=0
  for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:${AGENT_PORT}/metrics" >/dev/null 2>&1; then AGENT_UP=1; break; fi
    if [ "$(docker inspect -f '{{.State.Running}}' alumet-wire 2>/dev/null)" != "true" ]; then break; fi
    sleep 1
  done
  if [ "${AGENT_UP}" != "1" ]; then
    HAVE_AGENT=0
    AGENT_SKIP_REASON="agent container did not serve /metrics: $(docker logs alumet-wire 2>&1 | tail -1)"
    skip "${AGENT_SKIP_REASON}"
  fi
fi

if [ "${HAVE_AGENT}" = "1" ]; then
  sleep 6  # warmup: procfs must have flushed at least once (CI parity)
  LIVE_CAP="${TMP_DIR}/live-capture.prom"
  curl -fsS "http://127.0.0.1:${AGENT_PORT}/metrics" -o "${LIVE_CAP}" || true
  if [ -s "${LIVE_CAP}" ]; then
    cp "${LIVE_CAP}" /tmp/alumet-wire-capture.prom
    N_ALUMET="$(grep -cE '^[a-zA-Z_:][a-zA-Z0-9_:]*_alumet(\{| )' "${LIVE_CAP}" || true)"
    assert_pass "A" "live exposition captured (${N_ALUMET} '_alumet' samples) -> /tmp/alumet-wire-capture.prom"
    if ! diff <(grep -oE '^[a-zA-Z_:][a-zA-Z0-9_:]*' "${LIVE_CAP}" | sort -u) \
              <(grep -oE '^[a-zA-Z_:][a-zA-Z0-9_:]*' "${FIX}/alumet-wire-capture.prom" | sort -u) >/dev/null 2>&1; then
      note "live metric-name set drifted vs the committed fixture (upstream change?) — compare /tmp/alumet-wire-capture.prom with fixtures/"
    fi
  else
    assert_fail "A" "empty live capture from http://127.0.0.1:${AGENT_PORT}/metrics"
  fi

  if grep -qE '^[a-zA-Z_:][a-zA-Z0-9_:]*_alumet(\{| )' "${LIVE_CAP}"; then
    assert_pass "B-suffix" "default '_alumet' suffix present on the wire"
  else
    assert_fail "B-suffix" "no metric with the default '_alumet' suffix (exporter naming contract violated)"
  fi
  if grep -qE 'resource_consumer_kind="process"' "${LIVE_CAP}"; then
    assert_pass "B-label" "procfs process rows carry resource_consumer_kind=\"process\""
  else
    assert_fail "B-label" "no sample with resource_consumer_kind=\"process\" (label contract violated)"
  fi
  # The CI job's verbatim discovery pipeline.
  LIVE_METRIC="$(grep -oE '^[a-zA-Z_:][a-zA-Z0-9_:]*_alumet\{[^}]*resource_consumer_kind="process"' "${LIVE_CAP}" | head -1 | cut -d'{' -f1)"
  if [ -n "${LIVE_METRIC}" ]; then
    assert_pass "B-discovery" "CI discovery pipeline found per-process metric: ${LIVE_METRIC}"
  else
    assert_fail "B-discovery" "CI discovery pipeline found no '_alumet' metric with per-process rows"
  fi
else
  record_skip "A" "live capture skipped: ${AGENT_SKIP_REASON}"
  record_skip "B" "wire shape skipped: ${AGENT_SKIP_REASON}"
fi

# =============================================================================
# C: daemon e2e against the live agent (CI end-to-end parity, 4 ticks at 5s)
# =============================================================================
if [ "${HAVE_AGENT}" = "1" ] && [ -n "${LIVE_METRIC}" ]; then
  step "Daemon e2e vs live agent (C): 22s watch, no warns, counters move"
  {
    daemon_header
    cat <<EOF

[green.alumet]
endpoint = "http://127.0.0.1:${AGENT_PORT}/metrics"
scrape_interval_secs = 5
metric_name = "${LIVE_METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = 1.0

[green.alumet.service_mappings]
"wire-conformance-svc" = "process"
EOF
  } > "${TMP_DIR}/daemon-live.toml"
  if start_daemon daemon-live.toml daemon-live.log; then
    sleep 11
    C1="$(alumet_success_count)"
    FRESH1="$(alumet_freshness)"
    sleep 6
    C2="$(alumet_success_count)"
    FRESH2="$(alumet_freshness)"
    sleep 5
    stop_daemon
    if grep -qF "Alumet scraper started" "${TMP_DIR}/daemon-live.log"; then
      assert_pass "C-start" "Alumet scraper started against the live agent"
    else
      assert_fail "C-start" "no 'Alumet scraper started' line in the daemon log"
    fi
    if ! grep -qF "no samples matched the configured metric" "${TMP_DIR}/daemon-live.log" \
       && ! grep -qF "none of the configured service_mappings label values were present" "${TMP_DIR}/daemon-live.log"; then
      assert_pass "C-nowarn" "neither warn marker fired across 4 live ticks"
    else
      assert_fail "C-nowarn" "a warn marker fired against the live wire (naming or label contract regressed)"
    fi
    if [ "${C2}" -gt "${C1}" ] && [ "${C1}" -ge 1 ]; then
      assert_pass "C-counter" "scrape_total{success} increments (${C1} -> ${C2})"
    else
      assert_fail "C-counter" "scrape_total{success} did not increment (${C1} -> ${C2})"
    fi
    if python3 -c "import sys; sys.exit(0 if min(${FRESH1}, ${FRESH2}) < 7 else 1)"; then
      assert_pass "C-fresh" "last_scrape_age stays below one scrape+margin (${FRESH1}s / ${FRESH2}s)"
    else
      assert_fail "C-fresh" "last_scrape_age never dropped below 7s (${FRESH1}s / ${FRESH2}s)"
    fi
  else
    assert_fail "C" "daemon not ready on ${DAEMON_URL}: $(tail -2 "${TMP_DIR}/daemon-live.log" 2>/dev/null)"
  fi
  docker rm -f alumet-wire >/dev/null 2>&1 || true
else
  record_skip "C" "live e2e skipped: ${AGENT_SKIP_REASON:-no discovered metric}"
fi

# =============================================================================
# Frozen-capture legs: deterministic numbers off the committed fixture
# =============================================================================
step "Frozen mock: committed capture + one-line Scaphandre on :${MOCK_PORT}"
cp "${FIX}/alumet-wire-capture.prom" "${TMP_DIR}/mock/alumet.prom"
# One 42W process row matching dd-bridge-shop through exe/cmdline (leg F).
cat > "${TMP_DIR}/mock/scaph.prom" <<'EOF'
scaph_process_power_consumption_microwatts{exe="/usr/lib/jvm/java-25/bin/java",cmdline="java-jar/app/dd-bridge-shop.jar",pid="4242"} 42000000
EOF
lsof -ti "tcp:${MOCK_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
( cd "${TMP_DIR}/mock" && exec python3 -m http.server "${MOCK_PORT}" --bind 127.0.0.1 ) >/dev/null 2>&1 &
MOCK_PID=$!
disown "${MOCK_PID}" 2>/dev/null || true
for _ in $(seq 1 20); do
  curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet.prom" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet.prom" >/dev/null 2>&1 || die "frozen mock server not serving on :${MOCK_PORT}"

METRIC_FIX="$(discover_metric "${FIX}/alumet-wire-capture.prom")"
[ -n "${METRIC_FIX}" ] || die "no per-process '_alumet' metric discoverable in the committed fixture"
read -r J_SUM ROWS <<<"$(wire_joules_sum "${FIX}/alumet-wire-capture.prom" "${METRIC_FIX}")"
note "frozen legs use metric ${METRIC_FIX}: ${ROWS} positive process rows, sum ${J_SUM}"
if [ "${ROWS}" -ge 2 ]; then
  assert_pass "D-rows" "fixture carries ${ROWS} rows sharing the label value (summed-series precondition)"
else
  assert_fail "D-rows" "fixture carries only ${ROWS} process row(s); the summed-series leg needs >=2"
fi

step "Daemon (frozen): summed-label math (D) + precedence (F) + /api/energy (G3)"
{
  daemon_header green
  cat <<EOF

[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet.prom"
scrape_interval_secs = 5
metric_name = "${METRIC_FIX}"
label_key = "resource_consumer_kind"
energy_interval_secs = 1.0

[green.alumet.service_mappings]
"dd-bridge-shop" = "process"

[green.scaphandre]
endpoint = "http://127.0.0.1:${MOCK_PORT}/scaph.prom"
scrape_interval_secs = 5

[green.scaphandre.process_map."dd-bridge-shop"]
exe_contains = "bin/java"
cmdline_contains = "dd-bridge-shop.jar"
EOF
} > "${TMP_DIR}/daemon-d.toml"
start_daemon daemon-d.toml daemon-d.log || die "daemon (D/F) not ready: $(tail -2 "${TMP_DIR}/daemon-d.log")"
sleep 6
if seed_until_measured "dd-bridge-shop"; then
  assert_pass "F" "with Scaphandre configured AND matching, per_service_energy_model = alumet_rapl"
  KWH_D="${SEED_KWH}"
  if python3 -c "
import sys
exp = ${J_SUM} * 5 / (1.0 * 3.6e6)
got = ${KWH_D}
sys.exit(0 if abs(got - exp) / exp < 0.01 else 1)"; then
    assert_pass "D" "per_service_energy_kwh = ${KWH_D} == sum(${ROWS} rows)*5/3.6e6 within 1% (rows summed)"
  else
    assert_fail "D" "per_service_energy_kwh = ${KWH_D}, expected $(python3 -c "print(${J_SUM}*5/3.6e6)") (label-sharing rows not summed?)"
  fi
else
  assert_fail "F" "per_service_energy_model never reached alumet_rapl (got '${SEED_MODEL}') — precedence or coefficient path broken"
  record "D" "FAIL — not reached (F failed)"
  FAILS=$((FAILS + 1))
  KWH_D=""
fi
ENERGY_JSON="$(curl -fsS "${DAEMON_URL}/api/energy" 2>/dev/null)"
if printf '%s' "${ENERGY_JSON}" | python3 -c '
import sys, json
b = json.load(sys.stdin).get("backends", [])
ok = len(b) == 16 and b[0].get("backend") == "alumet" and b[0].get("configured") is True
sys.exit(0 if ok else 1)' 2>/dev/null; then
  assert_pass "G3" "/api/energy: 16 backends, alumet FIRST and configured"
else
  assert_fail "G3" "/api/energy shape wrong (want 16 rows, alumet first): $(printf '%s' "${ENERGY_JSON}" | head -c 160)"
fi
stop_daemon

# ── E: desync scaling, energy_interval_secs=5.0 must divide by exactly 5 ───
step "Daemon (frozen): desync x5 (E) — energy_interval_secs=5.0 vs 1.0"
{
  daemon_header green
  cat <<EOF

[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet.prom"
scrape_interval_secs = 5
metric_name = "${METRIC_FIX}"
label_key = "resource_consumer_kind"
energy_interval_secs = 5.0

[green.alumet.service_mappings]
"dd-bridge-shop" = "process"
EOF
} > "${TMP_DIR}/daemon-e.toml"
start_daemon daemon-e.toml daemon-e.log || die "daemon (E) not ready: $(tail -2 "${TMP_DIR}/daemon-e.log")"
sleep 6
if seed_until_measured "dd-bridge-shop"; then
  KWH_E="${SEED_KWH}"
  if python3 -c "
import sys
exp = ${J_SUM} * 5 / (5.0 * 3.6e6)
got = ${KWH_E}
sys.exit(0 if abs(got - exp) / exp < 0.01 else 1)"; then
    assert_pass "E-abs" "energy_interval_secs=5.0 -> kwh ${KWH_E} == expected/5 within 1%"
  else
    assert_fail "E-abs" "kwh ${KWH_E}, expected $(python3 -c "print(${J_SUM}/3.6e6)")"
  fi
  if [ -n "${KWH_D}" ] && python3 -c "
import sys
r = ${KWH_D} / ${KWH_E}
sys.exit(0 if 4.95 < r < 5.05 else 1)"; then
    assert_pass "E-ratio" "declared-interval desync rescales linearly: kwh(1.0)/kwh(5.0) = $(python3 -c "print(round(${KWH_D} / ${KWH_E}, 3))")"
  elif [ -n "${KWH_D}" ]; then
    assert_fail "E-ratio" "ratio kwh(1.0)/kwh(5.0) = $(python3 -c "print(${KWH_D} / ${KWH_E})") not in [4.95, 5.05]"
  else
    record_skip "E-ratio" "no kwh from leg D to compare against"
  fi
else
  assert_fail "E-abs" "coefficient never measured under energy_interval_secs=5.0 (got '${SEED_MODEL}')"
  record_skip "E-ratio" "not reached"
fi
stop_daemon

# ── G1: mistyped mapping, no-match warn latches once, scraping stays green ─
step "Daemon (frozen): mistyped mapping (G1) — 1s ticks, warn latches at tick 3"
{
  daemon_header
  cat <<EOF

[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet.prom"
scrape_interval_secs = 1
metric_name = "${METRIC_FIX}"
label_key = "resource_consumer_kind"
energy_interval_secs = 1.0

[green.alumet.service_mappings]
"ghost-svc" = "no-such-label-value"
EOF
} > "${TMP_DIR}/daemon-g1.toml"
start_daemon daemon-g1.toml daemon-g1.log || die "daemon (G1) not ready: $(tail -2 "${TMP_DIR}/daemon-g1.log")"
sleep 10
G1_SUCC="$(alumet_success_count)"
G1_FAIL="$(alumet_failed_count)"
stop_daemon
G1_NOMATCH="$(grep -cF "none of the configured service_mappings label values were present" "${TMP_DIR}/daemon-g1.log" || true)"
G1_ZERO="$(grep -cF "no samples matched the configured metric" "${TMP_DIR}/daemon-g1.log" || true)"
if [ "${G1_NOMATCH}" = "1" ] && [ "${G1_ZERO}" = "0" ]; then
  assert_pass "G1-warn" "no-match warn latched exactly once over ~9 ticks, zero-sample warn absent"
else
  assert_fail "G1-warn" "warn counts: no-match=${G1_NOMATCH} (want 1), zero-sample=${G1_ZERO} (want 0)"
fi
if [ "${G1_SUCC}" -ge 3 ] && [ "${G1_FAIL}" = "0" ]; then
  assert_pass "G1-healthy" "scraping stays healthy while the mapping warn fires (success=${G1_SUCC}, failed=0)"
else
  assert_fail "G1-healthy" "scrape counters off: success=${G1_SUCC} (want >=3), failed=${G1_FAIL} (want 0)"
fi

step "Daemon (frozen): empty service_mappings (G2) — startup warn once"
{
  daemon_header
  cat <<EOF

[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet.prom"
scrape_interval_secs = 1
metric_name = "${METRIC_FIX}"
label_key = "resource_consumer_kind"
energy_interval_secs = 1.0
EOF
} > "${TMP_DIR}/daemon-g2.toml"
start_daemon daemon-g2.toml daemon-g2.log || die "daemon (G2) not ready: $(tail -2 "${TMP_DIR}/daemon-g2.log")"
sleep 10
stop_daemon
G2_EMPTY="$(grep -cF "service_mappings is empty" "${TMP_DIR}/daemon-g2.log" || true)"
G2_NOMATCH="$(grep -cF "none of the configured service_mappings label values were present" "${TMP_DIR}/daemon-g2.log" || true)"
if [ "${G2_EMPTY}" = "1" ] && [ "${G2_NOMATCH}" = "0" ]; then
  assert_pass "G2" "empty mappings -> exactly one startup warn across ~9 ticks, no-match warn gated off"
else
  assert_fail "G2" "warn counts: empty=${G2_EMPTY} (want 1), no-match=${G2_NOMATCH} (want 0)"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel 0.9.12 Alumet measured-energy backend vs the real alumet-agent ${ALUMET_VERSION}."
  echo ""
  echo "| assertion | result |"
  echo "|---|---|"
  for row in "${SUMMARY[@]}"; do
    printf "| %s | %s |\n" "${row%%|*}" "${row#*|}"
  done
  echo ""
  if [ "${#NOTES[@]}" -gt 0 ]; then
    echo "Notes:"
    for n in "${NOTES[@]}"; do echo "- ${n}"; done
    echo ""
  fi
  echo "Artifacts: /tmp/alumet-wire-capture.prom (live capture, product-repo fixture candidate)"
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
