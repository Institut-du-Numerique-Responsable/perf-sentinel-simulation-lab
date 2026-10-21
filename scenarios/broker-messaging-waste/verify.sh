#!/usr/bin/env bash
# broker-messaging-waste: gate the messaging ingestion and the broker energy
# attribution added on top of 0.9.22 (product branch feature/async-support).
#
# The two coupled blocks it gates, messaging ingestion and broker energy
# attribution, are described in README.md.
#
# The product ships 2333 green unit tests, and the two-source arbitration is
# covered there against an INJECTED clock (take_broker_energy /
# patch_broker_energy take `now` as a parameter). That is precisely the limit:
# those tests never meet a scraper that delivers energy per interval and
# retroactively, that can answer WITHOUT the expected label, and that can die
# then come back. This scenario is the only place those three coexist. The
# arbitration was rewritten three times in review, each fix revealing the next,
# so legs A1-A6 map 1:1 onto the four rules the current code rests on.
#
# Legs (see README.md):
#   D    config: half-declared [green.broker_static], provider typo, cgroup
#        collisions (service_mappings and the database declaration), a broker
#        without an endpoint, and the two rejections that go through the
#        validator broker and database SHARE -- each naming THAT section.
#   A1   nominal, Alumet live and labelled: model is always alumet_rapl and
#        NEVER broker_specpower -- the declaration bills no measured window.
#   A2   energy sum over the window is the cgroup's own, not the declared
#        cluster's: double billing shows up as a near-doubling.
#   A3   Alumet cut: falls back to broker_specpower after staleness (3x the
#        scrape interval), with no window left without a figure.
#   A4   Alumet back: the first window after recovery does not stack measured +
#        declared. The retroactive delta reaches back over wall clock the
#        declaration already billed, and must be dropped exactly once.
#   A5   wrong label_value, healthy endpoint: broker_specpower continuously and
#        messaging_waste PRESENT. This is the review regression -- an endpoint
#        answering without the label measures nothing and must not suppress the
#        fallback.
#   A6   daemon booted with Alumet unreachable: the declaration bills from the
#        first windows. A never-scraped state must not read "fresh" during the
#        first staleness window.
#   A7   a late scrape banks a delta covering a hole the declaration already
#        billed, with NO scoring window running while that sample is fresh. The
#        path A4 cannot reach, and the one that needs the outage marker consulted
#        on the banked-delivery branch too.
#   B    disclosure v1.5: aggregate.messaging_waste with its three provenance
#        buckets and the invariant measured + declared + estimated ==
#        windows_with_figure. A broker_static-only period gives
#        measured_windows = 0; and re-hashing a real archived pre-v1.5 report
#        still yields its original content_hash (both new fields carry
#        skip_serializing_if, so the byte shape must be unchanged).
#   C    surfaces: `Broker waste` on /api/export/report, in `query monitor`'s
#        Energy tab and in the HTML dashboard, with no flicker across windows.
#   E    destination spellings the lab has no emitter for: RabbitMQ named and
#        default exchange, a Pulsar topic URL, an AMQP URI carrying credentials,
#        an IBM MQ / JMS queue, a routing-key glob.
#   E2   one RabbitMQ trace with three slow PRODUCER sends: exactly one
#        slow_messaging finding for probe-slow-rabbitmq, with three occurrences.
#   F3   the four crafted topologies, which localise any F1/F2 failure: receive
#        as sibling, as ancestor, a sibling that started BEFORE the receive (must
#        stay unlinked -- a false link is worse than none), and work under an
#        intermediate handler.
#   F1/2 the producer link on the REAL capture, per slice. Rate is over the
#        traces that are ANALYZABLE: half the linked consumer traces here are
#        CONSUMER-only and never enter the analysis at all.
#
# Self-contained: local release binary on loopback plus a python http.server
# serving the committed alumet-conformance capture of the REAL agent, augmented
# with one synthetic broker-cgroup series at a known joules-per-poll, so every
# figure is checkable arithmetic. No cluster, no Docker.
#
# The wall clock is compressed on purpose. What triggers the double billing is
# `scrape_interval > analysis batch cadence`, not the absolute 30s of the
# product report: the ratio is preserved (3s scrape vs a 1s trace TTL) and the
# durations shrink accordingly.
set -uo pipefail

SCENARIO="broker-messaging-waste"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_PROM="${SCRIPT_DIR}/../alumet-conformance/fixtures/alumet-wire-capture.prom"
CASES_GEN="${SCRIPT_DIR}/fixtures/broker_cases.py"
ORG_CONFIG="${SCRIPT_DIR}/../disclose/fixtures/org-config.toml"
# A real archived period predating the messaging block, and the OFFICIAL v1.4
# disclosure the previous release (0.9.22) wrote from it. Leg B re-verifies that
# report under the new binary: the two new fields carry skip_serializing_if, so
# its byte shape and therefore its content_hash must be untouched.
PREV_ARCHIVE="${SCRIPT_DIR}/../disclose/fixtures/reports-thr5.ndjson"
V14_REPORT="${SCRIPT_DIR}/fixtures/disclosure-v14-official.json"
ASTRO_FIX="${SCRIPT_DIR}/../astronomy-shop/fixtures"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}/mock"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14608}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14609}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
MOCK_PORT="${MOCK_PORT:-19095}"
SOCK="${TMP_DIR}/msg.sock"

# Cadence and the synthetic broker-cgroup reading. The daemon treats the metric
# as joules per energy_interval, so window energy is
#   value * scrape_interval / (energy_interval * 3.6e6)
# and 36000 J/1.0s over a 3s scrape is a round 0.03 kWh. Synthetic, like the
# memory-as-joules capture it rides on: physical realism is not the point,
# checkable arithmetic is.
SCRAPE_SECS=3
ENERGY_INTERVAL=1.0
STALENESS_SECS=$((SCRAPE_SECS * 3))      # the daemon's own rule, listeners.rs
BROKER_LABEL="kafka-cgroup"
BROKER_JOULES=36000
REGION="eu-west-3"
# kWh per second of wall clock while the measurement owns the timeline. The
# scrape count cancels out, so the expectation holds whatever the alignment.
KWH_PER_SEC="$(python3 -c "print(${BROKER_JOULES} / (${ENERGY_INTERVAL} * 3.6e6))")"

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
record() { SUMMARY+=("$1|$2"); }
note()   { NOTES+=("$1"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }
record_skip() { skip "$2"; record "$1" "SKIP — $2"; }

DAEMON_PID=""
MOCK_PID=""
SEED_PID=""
cleanup() {
  [ -n "${SEED_PID}" ] && kill "${SEED_PID}" 2>/dev/null || true
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  [ -n "${MOCK_PID}" ] && kill "${MOCK_PID}" 2>/dev/null || true
  rm -f "${SOCK}" 2>/dev/null || true
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -s "${BASE_PROM}" ] || die "base capture ${BASE_PROM} missing (alumet-conformance fixture)"
[ -s "${CASES_GEN}" ] || die "generator ${CASES_GEN} missing"

# ── mock energy endpoint ─────────────────────────────────────────────────────
# A static file is enough for the steady state: the exposition is a rate
# reading, so each scrape contributes exactly one scrape interval's worth.
#
# It is NOT enough for the recovery case. A real Alumet agent accumulates while
# perf-sentinel cannot reach it and hands the whole gap over on the first
# successful scrape after it comes back: that retroactive delta is the reason
# rule 4 exists. A constant file never catches up, so leg A4 would pass
# vacuously. `set_broker_joules` therefore rewrites the served value: the
# http.server re-reads the file per request, so one inflated value followed by a
# revert reproduces the catch-up without a dynamic server.
set_broker_joules() {  # $1 = joules per energy_interval to serve
  set_broker_row "${BROKER_LABEL}" "$1"
}

# Rename the label the broker row carries, so the endpoint keeps answering while
# the configured series stops existing: a cgroup rename in production, and the
# only way to make a series go stale without taking the endpoint down.
set_broker_joules_label() {  # $1 = label to serve the row under
  set_broker_row "$1" "${BROKER_JOULES}"
}

set_broker_row() {  # $1 = label_value, $2 = joules
  python3 - "${TMP_DIR}/mock/alumet-broker.prom" "${METRIC}" "${BROKER_LABEL}" "$1" "$2" <<'PY'
import sys
path, metric, configured, label, joules = sys.argv[1:6]
# Drop any row this helper previously wrote, under whatever label, so repeated
# calls never leave two competing series behind.
rows = [l for l in open(path) if 'resource_consumer_id="kafkacg"' not in l]
rows.append(f'{metric}{{kind="resident",resource_consumer_id="kafkacg",'
            f'resource_consumer_kind="{label}",resource_id="",'
            f'resource_kind="local_machine"}} {float(joules)}\n')
open(path, "w").writelines(rows)
PY
}

start_mock() {
  lsof -ti "tcp:${MOCK_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  ( cd "${TMP_DIR}/mock" && exec python3 -m http.server "${MOCK_PORT}" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  MOCK_PID=$!
  disown "${MOCK_PID}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet-broker.prom" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

stop_mock() {
  [ -n "${MOCK_PID}" ] && kill "${MOCK_PID}" 2>/dev/null || true
  lsof -ti "tcp:${MOCK_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  MOCK_PID=""
  # Only once the port really refuses does the daemon start failing scrapes.
  for _ in $(seq 1 20); do
    curl -fsS --max-time 1 "http://127.0.0.1:${MOCK_PORT}/alumet-broker.prom" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  return 1
}

# ── daemon ───────────────────────────────────────────────────────────────────
free_daemon_port() {
  pkill -f "perf-sentinel watch.*${TMP_DIR}/" 2>/dev/null || true
  for p in "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}"; do
    lsof -ti "tcp:${p}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  done
}

start_daemon() {  # $1 = config basename under TMP_DIR ; $2 = log basename
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  free_daemon_port
  rm -f "${SOCK}"
  sleep 1
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/$1" > "${TMP_DIR}/$2" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && break
    kill -0 "${DAEMON_PID}" 2>/dev/null || return 1   # exited on its own: config reject
    sleep 0.5
  done
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 || return 1
  for _ in $(seq 1 20); do [ -S "${SOCK}" ] && return 0; sleep 0.5; done
  return 1
}

stop_daemon() {
  [ -n "${SEED_PID}" ] && kill "${SEED_PID}" 2>/dev/null || true
  SEED_PID=""
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  wait "${DAEMON_PID}" 2>/dev/null || true
  DAEMON_PID=""
}

# Launch with a config expected to be REJECTED at load: the process must exit
# on its own within a couple of seconds and never answer /api/status.
expect_config_reject() {  # $1 = config ; $2 = log
  free_daemon_port
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/$1" > "${TMP_DIR}/$2" 2>&1 &
  local pid=$!
  sleep 2
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
    return 1
  fi
  wait "${pid}" 2>/dev/null || true
  return 0
}

# ── config writer ────────────────────────────────────────────────────────────
# $1 outfile, $2 broker label_value, $3 extra [daemon] lines, $4 extra sections.
# Both energy sources are declared together: that is the configuration the
# arbitration has to disambiguate, and the one the review regressions hid in.
write_config() {
  cat > "${TMP_DIR}/$1" <<EOF
[green]
enabled = true
default_region = "${REGION}"

[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
json_socket = "${SOCK}"
trace_ttl_ms = 1000
environment = "staging"
${3:-}

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5

[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet-broker.prom"
scrape_interval_secs = ${SCRAPE_SECS}
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}

[green.alumet.service_mappings]
"bus-svc" = "process"

[green.alumet.broker]
label_value = "$2"
region = "${REGION}"

[green.broker_static]
placement = "dedicated"
nodes = 3
instance_type = "m5.2xlarge"
provider = "aws"
region = "${REGION}"
${4:-}
EOF
}

# ── messaging traffic over the NDJSON socket ─────────────────────────────────
# 8 publishes to one destination per trace clears n_plus_one_min_occurrences=5,
# so every window carries both total_messaging_io_ops and an avoidable share.
# Timestamps are stamped at "now": the daemon evicts on trace_ttl_ms.
cat > "${TMP_DIR}/seed.py" <<'PY'
import json, os, socket, sys, time
from datetime import datetime, timezone

sock_path, interval = sys.argv[1], float(sys.argv[2])
n = 0
while True:
    now = datetime.now(timezone.utc)
    ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
    tid = f"bus{n:029d}"
    events = [{
        "timestamp": ts, "trace_id": tid, "span_id": f"s{i:015d}",
        "parent_span_id": "s000000000000000", "service": "bus-svc",
        "cloud_region": os.environ.get("SEED_REGION", "eu-west-3"),
        "type": "messaging", "operation": "kafka", "target": "orders",
        "duration_us": 1500,
        "source": {"endpoint": "POST /checkout", "method": "CheckoutService::submit"},
    } for i in range(1, 9)]
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        s.sendall((json.dumps(events) + "\n").encode())
        s.close()
    except OSError:
        pass
    n += 1
    time.sleep(interval)
PY

start_seeding() {  # $1 = interval seconds
  [ -n "${SEED_PID}" ] && kill "${SEED_PID}" 2>/dev/null || true
  python3 "${TMP_DIR}/seed.py" "${SOCK}" "${1:-0.4}" >/dev/null 2>&1 &
  SEED_PID=$!
}

# ── report / archive readers ─────────────────────────────────────────────────
# messaging_waste liveness on /api/export/report. Separates a real null from a
# loopback flake so the sticky legs never read a fetch error as a state change.
# Exit: 0 present, 1 absent (fetch+parse fine), 2 fetch/parse failed.
msg_waste_present() {
  local body
  body="$(curl -fsS "${DAEMON_URL}/api/export/report" 2>/dev/null)" || return 2
  printf '%s' "${body}" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
sys.exit(0 if ((d.get("green_summary") or {}).get("messaging_waste")) else 1)'
}

msg_waste_model() {  # prints the current model tag, or "" when absent
  curl -fsS "${DAEMON_URL}/api/export/report" 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(((d.get("green_summary") or {}).get("messaging_waste") or {}).get("model", ""))' 2>/dev/null || echo ""
}

# Sum archived window energy per provenance tag. Tolerant of a torn trailing
# line from the still-running daemon: a raw json.loads-per-line pass would
# abort the whole count on one bad line.
# Prints: "<model> <windows> <sum_kwh> <max_window_kwh>" per tag.
#
# $2 = "steady" restricts the count to windows at or after the FIRST measured
# one. Boot is not the nominal regime: before any scrape has succeeded the
# declaration legitimately bills (that is what leg A6 asserts), so leg A1 must
# not read those windows as the declaration stealing measured time.
msg_windows_by_model() {  # $1 = archive ndjson (may be absent) ; $2 = steady|all
  python3 - "$1" "${2:-all}" <<'PY'
import json, sys
from collections import defaultdict
rows = []
try:
    fh = open(sys.argv[1])
except OSError:
    sys.exit()
for line in fh:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        # A torn trailing line from the still-running daemon: skipping it beats
        # aborting the whole count.
        continue
    m = ((o.get("report") or {}).get("disclosure_waste") or {}).get("messaging")
    if m:
        rows.append((m.get("model", "?"), m.get("energy_kwh") or 0.0))
if sys.argv[2] == "steady":
    first = next((i for i, (mo, _) in enumerate(rows) if mo == "alumet_rapl"), None)
    rows = rows[first:] if first is not None else []
agg = defaultdict(lambda: [0, 0.0, 0.0])
for model, e in rows:
    a = agg[model]
    a[0] += 1
    a[1] += e
    a[2] = max(a[2], e)
for model, (n, tot, mx) in sorted(agg.items()):
    print(f"{model} {n} {tot!r} {mx!r}")
PY
}

model_field() {  # $1 = archive, $2 = model tag, $3 = 1|2|3 (windows|sum|max), $4 = steady|all
  msg_windows_by_model "$1" "${4:-all}" \
    | awk -v m="$2" -v f="$3" '$1==m {print $(f+1); found=1} END {if(!found) print 0}'
}

# Successful Alumet scrapes so far, from the daemon's own /metrics. Used both to
# prove leg A5's endpoint is genuinely healthy and to serve leg A4's catch-up
# reading for exactly one scrape.
alumet_success_count() {
  curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null | awk '
    index($0,"perf_sentinel_alumet_scrape_total")==1 && index($0,"status=\"success\"")>0 {print int($2); f=1; exit}
    END {if(!f) print 0}'
}

# =============================================================================
# Setup: broker-augmented exposition + metric discovery
# =============================================================================
step "Setup: frozen real-agent capture + one synthetic ${BROKER_LABEL} row on :${MOCK_PORT}"
cp "${BASE_PROM}" "${TMP_DIR}/mock/alumet-broker.prom"

# The broker cgroup shares the discovered per-process metric name: the config
# carries a single metric_name, and upstream's unit-suffix branch is inverted,
# so the name is always read off the wire rather than hardcoded.
METRIC="$(python3 - "${BASE_PROM}" <<'PY'
import collections, re, sys
c = collections.Counter()
for line in open(sys.argv[1]):
    if line.startswith('#'):
        continue
    m = re.match(r'^([a-zA-Z_:][a-zA-Z0-9_:]*_alumet)\{(.*)\}\s+(\S+)', line)
    if not m:
        continue
    name, labels, val = m.groups()
    try:
        v = float(val)
    except ValueError:
        continue
    if 'resource_consumer_kind="process"' in labels and v > 0:
        c[name] += 1
print(c.most_common(1)[0][0] if c else "")
PY
)"
[ -n "${METRIC}" ] || die "no per-process _alumet metric discoverable in ${BASE_PROM}"

set_broker_joules "${BROKER_JOULES}"
start_mock || die "mock not serving on :${MOCK_PORT}"
note "metric ${METRIC}; broker cgroup ${BROKER_LABEL}=${BROKER_JOULES} J/poll -> ${KWH_PER_SEC} kWh per second of measured wall clock"
note "scrape ${SCRAPE_SECS}s > batch cadence (trace_ttl_ms=1000): staleness window ${STALENESS_SECS}s"

# =============================================================================
# Leg D: config validation (fast, no traffic needed)
# =============================================================================
step "D: the seven configuration refusals happen at load, plus one acceptance"
D_FAILS=0
d_case() {  # $1 = label, $2 = config file, $3 = grep pattern the error must match
  if expect_config_reject "$2" "$2.log"; then
    if grep -qi -- "$3" "${TMP_DIR}/$2.log"; then
      ok "$1 rejected, message matches /$3/"
    else
      color_red "    FAIL: $1 rejected but the message does not match /$3/"
      note "D $1: $(tail -2 "${TMP_DIR}/$2.log" | tr '\n' ' ')"
      D_FAILS=$((D_FAILS + 1))
    fi
  else
    color_red "    FAIL: $1 was ACCEPTED at load"
    D_FAILS=$((D_FAILS + 1))
  fi
}

# d1: nodes without instance_type -> the section would be silently inert.
write_config d1.toml "${BROKER_LABEL}" "" ""
python3 - "${TMP_DIR}/d1.toml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'^instance_type = .*\n', '', s, flags=re.M)
open(p, 'w').write(s)
PY
d_case "d1 half-declared [green.broker_static] (nodes without instance_type)" d1.toml "instance_type"

# d2: provider typo -> an unrecognised value would silently resolve to generic.
write_config d2.toml "${BROKER_LABEL}" "" ""
sed -i.bak 's/provider = "aws"/provider = "asw"/' "${TMP_DIR}/d2.toml"
d_case "d2 provider typo (asw)" d2.toml "provider"

# d3: the broker cgroup also mapped as a service.
write_config d3.toml "${BROKER_LABEL}" "" ""
sed -i.bak "s/\"bus-svc\" = \"process\"/\"bus-svc\" = \"${BROKER_LABEL}\"/" "${TMP_DIR}/d3.toml"
d_case "d3 broker cgroup collides with service_mappings" d3.toml "${BROKER_LABEL}"

# d4: the same cgroup declared as both broker and database.
write_config d4.toml "${BROKER_LABEL}" "" "
[green.alumet.database]
label_value = \"${BROKER_LABEL}\"
region = \"${REGION}\"
"
d_case "d4 same cgroup declared broker AND database" d4.toml "${BROKER_LABEL}"

# d5: an error on [green.alumet.broker] must name THAT section, not the
# database one it shares its validator with. A broker declared without an
# [green.alumet] endpoint is the branch's own error path: no scraper starts, so
# the figure would never appear.
write_config d5.toml "${BROKER_LABEL}" "" ""
python3 - "${TMP_DIR}/d5.toml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'^endpoint = .*\n', '', s, count=1, flags=re.M)
open(p, 'w').write(s)
PY
if expect_config_reject d5.toml d5.log; then
  if grep -q "green.alumet.broker" "${TMP_DIR}/d5.log" \
     && ! grep -q "green.alumet.database" "${TMP_DIR}/d5.log"; then
    ok "d5 broker without an Alumet endpoint: error names [green.alumet.broker], not the database section"
  else
    color_red "    FAIL: d5 error does not name [green.alumet.broker] alone"
    note "D d5: $(tail -2 "${TMP_DIR}/d5.log" | tr '\n' ' ')"
    D_FAILS=$((D_FAILS + 1))
  fi
else
  color_red "    FAIL: d5 [green.alumet.broker] without an endpoint was ACCEPTED"
  D_FAILS=$((D_FAILS + 1))
fi

# d7: the section-naming proof that goes through the validator broker and
# database SHARE (`validate_workload_fields`), which is where a mix-up would
# actually happen. An invalid region charset is one of the two things that
# validator rejects. The other is a control char in label_value. Note that a
# label_value with spaces or '!' is deliberately ACCEPTED, cgroup names carry
# odd characters, so only length and control chars are bounded there.
write_config d7.toml "${BROKER_LABEL}" "" ""
sed -i.bak "s/^region = \"${REGION}\"$/region = \"eu west 3!!\"/" "${TMP_DIR}/d7.toml"
if expect_config_reject d7.toml d7.log; then
  if grep -q "green.alumet.broker" "${TMP_DIR}/d7.log" \
     && ! grep -q "green.alumet.database" "${TMP_DIR}/d7.log"; then
    ok "d7 invalid broker region through the shared validator: error names [green.alumet.broker] alone"
  else
    color_red "    FAIL: d7 error does not name [green.alumet.broker] alone"
    note "D d7: $(tail -2 "${TMP_DIR}/d7.log" | tr '\n' ' ')"
    D_FAILS=$((D_FAILS + 1))
  fi
else
  color_red "    FAIL: d7 invalid broker region was ACCEPTED"
  D_FAILS=$((D_FAILS + 1))
fi

# d8: a control char in the broker label_value is refused, but by the TOML
# parser, before the config validator runs, so the error cannot name the
# section. `validate_workload_fields`' own control-char branch is therefore
# unreachable from a config file and is defence-in-depth for programmatic
# construction only. Asserting the rejection is truthful. Asserting the section
# name here would be asserting the TOML crate's message.
write_config d8.toml "$(printf 'kafka\007cgroup')" "" ""
if expect_config_reject d8.toml d8.log; then
  ok "d8 control char in the broker label_value refused fail-closed (at TOML parse, so unnamed)"
else
  color_red "    FAIL: d8 control char in the broker label_value was ACCEPTED"
  D_FAILS=$((D_FAILS + 1))
fi

# provider absent / empty must be ACCEPTED and resolve to generic.
write_config d6.toml "${BROKER_LABEL}" "" ""
sed -i.bak 's/provider = "aws"/provider = ""/' "${TMP_DIR}/d6.toml"
if start_daemon d6.toml d6.log; then
  ok "d6 empty provider accepted (resolves to generic)"
  stop_daemon
else
  color_red "    FAIL: d6 empty provider was REJECTED (must resolve to generic)"
  D_FAILS=$((D_FAILS + 1))
fi

if [ "${D_FAILS}" -eq 0 ]; then
  assert_pass "D" "8/8 configuration cases behave (7 refusals + empty provider accepted)"
else
  assert_fail "D" "${D_FAILS} configuration case(s) wrong"
fi

# =============================================================================
# Leg A1 + A2: nominal regime -- measurement owns the timeline
# =============================================================================
step "A1/A2: nominal (Alumet live + labelled) for ~${STALENESS_SECS}0s"
write_config a1.toml "${BROKER_LABEL}" "
[daemon.archive]
path = \"${TMP_DIR}/archive-a1.ndjson\"
max_size_mb = 100
max_files = 4" ""
# Bracket the whole daemon lifetime, not just the polling loop: the scraper
# starts at boot and the first scored window banks everything since then.
A1_T0=${SECONDS}
if start_daemon a1.toml a1.log; then
  start_seeding 0.4
  A1_MODELS=""
  # Wait for the measurement to take over before sampling: until the first
  # scrape lands, the declaration bills legitimately (leg A6 asserts exactly
  # that), and counting those boot windows here would fail A1 for being right.
  for _ in $(seq 1 20); do
    [ "$(msg_waste_model)" = "alumet_rapl" ] && break
    sleep 1
  done
  A1_STEADY_T0=${SECONDS}
  # Then poll across several scrape intervals, sampling the live tag so a single
  # flip to the declaration is caught even if the archive smooths it out.
  for _ in $(seq 1 20); do
    sleep 2
    m="$(msg_waste_model)"
    [ -n "${m}" ] && A1_MODELS="${A1_MODELS} ${m}"
  done
  stop_daemon
  A1_ELAPSED=$((SECONDS - A1_T0))

  # `steady` drops everything before the first measured window.
  A1_DECL_WINDOWS="$(model_field "${TMP_DIR}/archive-a1.ndjson" broker_specpower 1 steady)"
  A1_BOOT_DECL="$(model_field "${TMP_DIR}/archive-a1.ndjson" broker_specpower 1)"
  A1_MEAS_WINDOWS="$(model_field "${TMP_DIR}/archive-a1.ndjson" alumet_rapl 1)"
  A1_MEAS_SUM="$(model_field "${TMP_DIR}/archive-a1.ndjson" alumet_rapl 2)"
  note "A1 live model samples (steady state only):${A1_MODELS:- none}"
  note "A1 archive: alumet_rapl ${A1_MEAS_WINDOWS} windows sum=${A1_MEAS_SUM} kWh; broker_specpower ${A1_BOOT_DECL} total of which ${A1_DECL_WINDOWS} after the measurement took over"
  note "A1 steady state entered after $((A1_STEADY_T0 - A1_T0))s"

  if [ "${A1_MEAS_WINDOWS}" -eq 0 ]; then
    assert_fail "A1" "no measured window at all — messaging_waste never appeared (see ${TMP_DIR}/a1.log)"
    assert_fail "A2" "no measured window to sum"
  else
    # Rule 1: the declaration must bill no window the measurement covered.
    if [ "${A1_DECL_WINDOWS}" -eq 0 ] \
       && ! printf '%s' "${A1_MODELS}" | grep -q broker_specpower; then
      assert_pass "A1" "model always alumet_rapl over ${A1_MEAS_WINDOWS} windows once the measurement owned the timeline; broker_specpower billed only the ${A1_BOOT_DECL} boot window(s) before the first scrape"
    else
      assert_fail "A1" "declaration billed ${A1_DECL_WINDOWS} window(s) while the measurement was live (samples:${A1_MODELS})"
    fi
    # Closed form independent of the scrape count: elapsed * J / (interval * 3.6e6).
    # A per-tick double billing lands near 2x, far outside the tolerance.
    python3 - "${A1_MEAS_SUM}" "${A1_ELAPSED}" "${KWH_PER_SEC}" > "${TMP_DIR}/a2.txt" <<'PY'
import sys
got, elapsed, per_sec = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
exp = elapsed * per_sec
# Wide on the low side: the last scrape of the run is banked but not yet
# published, and the daemon spends a second or two booting before the first
# one. Tight enough on the high side that a per-tick double billing (~2x, the
# first failure mode this arbitration had) cannot hide inside it.
lo, hi = exp * 0.55, exp * 1.35
print(f"{got!r} {exp!r} {lo!r} {hi!r} {'OK' if lo <= got <= hi else 'BAD'}")
PY
    read -r A2_GOT A2_EXP A2_LO A2_HI A2_VERDICT < "${TMP_DIR}/a2.txt"
    if [ "${A2_VERDICT}" = "OK" ]; then
      assert_pass "A2" "measured sum ${A2_GOT} kWh over ${A1_ELAPSED}s ≈ expected ${A2_EXP} (band ${A2_LO}..${A2_HI}); no double billing"
    else
      assert_fail "A2" "measured sum ${A2_GOT} kWh over ${A1_ELAPSED}s outside ${A2_LO}..${A2_HI} (expected ${A2_EXP}) — double billing or lost energy"
    fi
  fi
else
  assert_fail "A1" "daemon did not start (see ${TMP_DIR}/a1.log)"
  assert_fail "A2" "daemon did not start"
fi

# =============================================================================
# Leg A3 + A4: cut Alumet, then bring it back
# =============================================================================
step "A3/A4: cut Alumet past staleness (${STALENESS_SECS}s), then restore it"
write_config a34.toml "${BROKER_LABEL}" "
[daemon.archive]
path = \"${TMP_DIR}/archive-a34.ndjson\"
max_size_mb = 100
max_files = 4" ""
if start_daemon a34.toml a34.log; then
  start_seeding 0.4
  sleep $((SCRAPE_SECS * 3))                 # settle into the measured regime
  note "A3: ${A34_PRE_WINDOWS:=$(model_field "${TMP_DIR}/archive-a34.ndjson" alumet_rapl 1)} measured windows before cutting Alumet"

  stop_mock || note "A3: mock port did not go quiet"
  OUTAGE_START=${SECONDS}
  sleep $((STALENESS_SECS + SCRAPE_SECS * 3))
  A34_DECL="$(model_field "${TMP_DIR}/archive-a34.ndjson" broker_specpower 1)"
  A34_OUTAGE_SECS=$((SECONDS - OUTAGE_START))
  # Rule 3: the fallback takes over rather than leaving a hole.
  if [ "${A34_DECL}" -gt 0 ]; then
    assert_pass "A3" "fell back to broker_specpower (${A34_DECL} declared windows) after ${A34_OUTAGE_SECS}s without Alumet"
  else
    assert_fail "A3" "no declared window after ${A34_OUTAGE_SECS}s without Alumet — the figure went dark instead of falling back"
  fi

  # Rule 4: the recovery delta reaches back over wall clock the declaration
  # already billed, so it must be dropped exactly once.
  #
  # Serve the catch-up a real agent would hand over: the whole outage's joules
  # in ONE reading, then revert. Exactly one, tracked through the daemon's own
  # success counter: a fixed sleep would let a second inflated scrape through
  # and the leg would then fail on the test's own excess, not the product's.
  A34_PRE_SUM="$(model_field "${TMP_DIR}/archive-a34.ndjson" alumet_rapl 2)"
  CATCHUP_JOULES="$(python3 -c "print(${BROKER_JOULES} * ${A34_OUTAGE_SECS} / ${SCRAPE_SECS})")"
  set_broker_joules "${CATCHUP_JOULES}"
  A34_SCRAPES_BEFORE="$(alumet_success_count)"
  start_mock || note "A4: mock did not come back"
  A34_CATCHUP_SERVED=0
  for _ in $(seq 1 $((SCRAPE_SECS * 10))); do
    if [ "$(alumet_success_count)" -gt "${A34_SCRAPES_BEFORE}" ]; then
      A34_CATCHUP_SERVED=1
      break
    fi
    sleep 0.5
  done
  set_broker_joules "${BROKER_JOULES}"
  [ "${A34_CATCHUP_SERVED}" -eq 1 ] || note "A4: the catch-up reading may not have been scraped at all"
  sleep $((SCRAPE_SECS * 3))
  stop_daemon
  A34_POST_SUM="$(model_field "${TMP_DIR}/archive-a34.ndjson" alumet_rapl 2)"
  note "A3/A4 archive: $(msg_windows_by_model "${TMP_DIR}/archive-a34.ndjson" | tr '\n' ';')"
  note "A4: outage ${A34_OUTAGE_SECS}s, catch-up reading ${CATCHUP_JOULES} J/poll served for ~$((SCRAPE_SECS * 2))s"
  python3 - "${A34_PRE_SUM}" "${A34_POST_SUM}" "${A34_OUTAGE_SECS}" "${SCRAPE_SECS}" "${KWH_PER_SEC}" > "${TMP_DIR}/a4.txt" <<'PY'
import sys
pre, post, outage, scrape, per_sec = (float(x) for x in sys.argv[1:6])
gained = post - pre
# Energy the outage represents: what the declaration already billed, and what
# the single catch-up reading would re-deliver if it were not discarded.
outage_kwh = outage * per_sec
# An honest recovery bills only the steady scrapes it actually ran for, ~4
# intervals here. The catch-up reading is one whole outage on its own, so the
# two regimes are separated by a wide margin rather than a judgement call.
honest_cap = per_sec * scrape * 4
verdict = "OK" if gained < outage_kwh * 0.75 else "BAD"
print(f"{gained!r} {honest_cap!r} {outage_kwh!r} {verdict}")
PY
  read -r A4_GAIN A4_CAP A4_OUTAGE_KWH A4_VERDICT < "${TMP_DIR}/a4.txt"
  if [ "${A4_GAIN}" = "0" ] || [ "${A4_GAIN}" = "0.0" ]; then
    assert_fail "A4" "no measured energy after recovery — the measurement never resumed"
  elif [ "${A4_VERDICT}" = "OK" ]; then
    assert_pass "A4" "recovery added ${A4_GAIN} kWh (honest window ~${A4_CAP}); the outage's own ${A4_OUTAGE_KWH} kWh was not re-delivered on top of the declaration"
  else
    assert_fail "A4" "recovery added ${A4_GAIN} kWh, at or above the outage's own ${A4_OUTAGE_KWH} kWh — the retroactive delta was billed twice"
    # A4 and A7 share one root cause when both fail: the outage marker is a
    # consuming swap, and a stale tick spaced below the declared source's
    # MIN_BILLABLE_MS (1s) consumes it without re-setting it, because
    # take_window_kwh returned None so mark_outage_billed never ran. The batch
    # cadence is therefore load-bearing in this leg, not incidental: spacing the
    # windows above 1s makes both legs pass on the same binary.
    note "A4/A7: if both fail, suspect the outage marker being consumed by a sub-second stale tick, not two separate defects"
  fi
else
  assert_fail "A3" "daemon did not start (see ${TMP_DIR}/a34.log)"
  assert_fail "A4" "daemon did not start"
fi

# =============================================================================
# Leg A5: healthy endpoint, wrong label -- the review regression
# =============================================================================
step "A5: label_value absent from a healthy exposition (the review regression)"
start_mock >/dev/null 2>&1 || true
write_config a5.toml "no-such-cgroup" "
[daemon.archive]
path = \"${TMP_DIR}/archive-a5.ndjson\"
max_size_mb = 100
max_files = 4" ""
if start_daemon a5.toml a5.log; then
  start_seeding 0.4
  A5_MODELS=""
  for _ in $(seq 1 10); do
    sleep 2
    m="$(msg_waste_model)"
    [ -n "${m}" ] && A5_MODELS="${A5_MODELS} ${m}"
  done
  # The endpoint has to be demonstrably healthy, otherwise this leg silently
  # degrades into A3 and proves nothing about the label path.
  A5_SCRAPES="$(alumet_success_count)"
  stop_daemon
  A5_DECL="$(model_field "${TMP_DIR}/archive-a5.ndjson" broker_specpower 1)"
  A5_MEAS="$(model_field "${TMP_DIR}/archive-a5.ndjson" alumet_rapl 1)"
  note "A5: successful scrapes=${A5_SCRAPES}, declared windows=${A5_DECL}, measured windows=${A5_MEAS}, live samples:${A5_MODELS:- none}"
  if [ "${A5_SCRAPES}" -lt 1 ]; then
    assert_fail "A5" "the endpoint never scraped successfully — this leg degenerated into A3 and proves nothing"
  elif [ "${A5_DECL}" -gt 0 ] && [ "${A5_MEAS}" -eq 0 ]; then
    assert_pass "A5" "${A5_SCRAPES} successful scrapes without the label: messaging_waste PRESENT, ${A5_DECL} windows all broker_specpower"
  elif [ "${A5_DECL}" -eq 0 ] && [ "${A5_MEAS}" -eq 0 ]; then
    assert_fail "A5" "messaging_waste absent entirely on a valid config — the endpoint answered without the label and suppressed the fallback"
  else
    assert_fail "A5" "unexpected mix: ${A5_MEAS} measured / ${A5_DECL} declared windows with a label that measures nothing"
  fi
else
  assert_fail "A5" "daemon did not start (see ${TMP_DIR}/a5.log)"
fi

# =============================================================================
# Leg A6: Alumet unreachable from the very first tick
# =============================================================================
step "A6: boot with Alumet unreachable (a never-scraped state must not read fresh)"
stop_mock || note "A6: mock port did not go quiet"
write_config a6.toml "${BROKER_LABEL}" "
[daemon.archive]
path = \"${TMP_DIR}/archive-a6.ndjson\"
max_size_mb = 100
max_files = 4" ""
if start_daemon a6.toml a6.log; then
  start_seeding 0.4
  # Deliberately shorter than the staleness window: a state never scraped must
  # not be treated as fresh while it waits out its first staleness window.
  sleep $((STALENESS_SECS - 1))
  A6_EARLY_DECL="$(model_field "${TMP_DIR}/archive-a6.ndjson" broker_specpower 1)"
  A6_EARLY_MEAS="$(model_field "${TMP_DIR}/archive-a6.ndjson" alumet_rapl 1)"
  sleep $((SCRAPE_SECS * 3))
  stop_daemon
  A6_DECL="$(model_field "${TMP_DIR}/archive-a6.ndjson" broker_specpower 1)"
  note "A6: within the first staleness window declared=${A6_EARLY_DECL} measured=${A6_EARLY_MEAS}; total declared=${A6_DECL}"
  if [ "${A6_EARLY_MEAS}" -gt 0 ]; then
    assert_fail "A6" "${A6_EARLY_MEAS} window(s) tagged alumet_rapl before any scrape ever succeeded — a never-scraped state read as fresh"
  elif [ "${A6_EARLY_DECL}" -gt 0 ]; then
    assert_pass "A6" "declaration billed ${A6_EARLY_DECL} window(s) inside the first staleness window, none measured"
  elif [ "${A6_DECL}" -gt 0 ]; then
    assert_fail "A6" "the figure only appeared after the first staleness window (${A6_DECL} declared) — the boot windows were lost"
  else
    assert_fail "A6" "no figure at all with Alumet down from boot (see ${TMP_DIR}/a6.log)"
  fi
else
  assert_fail "A6" "daemon did not start (see ${TMP_DIR}/a6.log)"
fi

# =============================================================================
# Leg A7: a late scrape banking a delta over a hole the declaration already billed
# =============================================================================
# The path A4 does not reach. A4 has a scoring window run while the catch-up
# sample is fresh, so the measurement legitimately owns that window. Here NO
# scoring window runs while it is fresh, which is what happens when traffic is
# quiet or batches are shed, so the banked delta is still pending when the
# series goes stale again. The branch that delivers banked joules must consult
# `billed_during_outage`: the declaration already paid for that wall clock.
#
# Step 5 ("no scoring window runs") is the hard part, and it is why this leg
# stops the seeder rather than trusting timing: with no traces there is no batch,
# so there is no scored window. Asserted, not assumed, the leg fails loudly if
# windows kept appearing during the quiet stretch.
step "A7: label returns for one inflated scrape while no window scores, then goes stale"
start_mock >/dev/null 2>&1 || true
set_broker_joules "${BROKER_JOULES}"
write_config a7.toml "${BROKER_LABEL}" "
[daemon.archive]
path = \"${TMP_DIR}/archive-a7.ndjson\"
max_size_mb = 100
max_files = 4" ""
if start_daemon a7.toml a7.log; then
  start_seeding 0.4
  # 1. measured regime
  for _ in $(seq 1 20); do
    [ "$(msg_waste_model)" = "alumet_rapl" ] && break
    sleep 1
  done
  A7_STEP1="$(msg_waste_model)"

  # 2/3. the label disappears while the endpoint stays healthy -> the
  #      declaration bills the hole (this is case 5's mechanism, known good).
  set_broker_joules_label "gone-cgroup"
  HOLE_START=${SECONDS}
  sleep $((STALENESS_SECS + SCRAPE_SECS * 2))
  A7_DECL_BEFORE="$(model_field "${TMP_DIR}/archive-a7.ndjson" broker_specpower 1)"
  A7_MEAS_SUM_BEFORE="$(model_field "${TMP_DIR}/archive-a7.ndjson" alumet_rapl 2)"

  # 4/5. stop scoring FIRST, then let the label return for exactly one inflated
  #      scrape. No traffic -> no batch -> no window while the sample is fresh.
  [ -n "${SEED_PID}" ] && kill "${SEED_PID}" 2>/dev/null || true
  SEED_PID=""
  sleep 2
  A7_WINDOWS_AT_QUIESCE="$(wc -l < "${TMP_DIR}/archive-a7.ndjson" 2>/dev/null | tr -d ' ')"
  A7_HOLE_SECS=$((SECONDS - HOLE_START))
  A7_CATCHUP="$(python3 -c "print(${BROKER_JOULES} * ${A7_HOLE_SECS} / ${SCRAPE_SECS})")"
  A7_SCRAPES_BEFORE="$(alumet_success_count)"
  set_broker_joules "${A7_CATCHUP}"          # label back, inflated, one scrape
  for _ in $(seq 1 $((SCRAPE_SECS * 10))); do
    [ "$(alumet_success_count)" -gt "${A7_SCRAPES_BEFORE}" ] && break
    sleep 0.5
  done
  set_broker_joules_label "gone-cgroup"      # 6. straight back to stale
  A7_WINDOWS_AFTER_QUIESCE="$(wc -l < "${TMP_DIR}/archive-a7.ndjson" 2>/dev/null | tr -d ' ')"
  sleep $((STALENESS_SECS + 1))

  # then a scoring window runs again
  start_seeding 0.4
  sleep $((SCRAPE_SECS * 3))
  stop_daemon
  A7_MEAS_SUM_AFTER="$(model_field "${TMP_DIR}/archive-a7.ndjson" alumet_rapl 2)"
  A7_GAIN="$(python3 -c "print(${A7_MEAS_SUM_AFTER} - ${A7_MEAS_SUM_BEFORE})")"
  A7_HOLE_KWH="$(python3 -c "print(${A7_HOLE_SECS} * ${KWH_PER_SEC})")"
  note "A7: step1 model=${A7_STEP1}, hole ${A7_HOLE_SECS}s billed over ${A7_DECL_BEFORE} declared windows, catch-up ${A7_CATCHUP} J/poll"
  note "A7: archive windows ${A7_WINDOWS_AT_QUIESCE} -> ${A7_WINDOWS_AFTER_QUIESCE} during the quiet stretch (must not grow)"
  note "A7: alumet_rapl sum ${A7_MEAS_SUM_BEFORE} -> ${A7_MEAS_SUM_AFTER} (gain ${A7_GAIN}, the hole itself is worth ${A7_HOLE_KWH})"

  if [ "${A7_STEP1}" != "alumet_rapl" ]; then
    assert_fail "A7" "never reached the measured regime (model=${A7_STEP1:-<none>}), so the sequence never started"
  elif [ "${A7_DECL_BEFORE}" -eq 0 ]; then
    assert_fail "A7" "the declaration never billed the hole, so there is nothing for the late delta to double-bill"
  elif [ "${A7_WINDOWS_AFTER_QUIESCE}" != "${A7_WINDOWS_AT_QUIESCE}" ]; then
    record_skip "A7" "a window scored during the quiet stretch (${A7_WINDOWS_AT_QUIESCE} -> ${A7_WINDOWS_AFTER_QUIESCE}), so step 5 did not hold and this leg proves nothing — covered upstream by a deterministic unit test"
  elif python3 -c "import sys; sys.exit(0 if ${A7_GAIN} < ${A7_HOLE_KWH} * 0.25 else 1)"; then
    assert_pass "A7" "the banked delta was discarded: alumet_rapl gained ${A7_GAIN} kWh across the resume, against ${A7_HOLE_KWH} kWh the declaration already billed"
  else
    assert_fail "A7" "alumet_rapl gained ${A7_GAIN} kWh across the resume, at or near the ${A7_HOLE_KWH} kWh the declaration already billed — the banked delta was published as a measurement"
  fi
else
  assert_fail "A7" "daemon did not start (see ${TMP_DIR}/a7.log)"
fi

# =============================================================================
# Leg B: disclosure v1.5
# =============================================================================
step "B: disclose v1.5 — three-term invariant, declared-only shape, v1.4 hash"
B_FAILS=0
B_SRC=""
for a in archive-a1 archive-a34 archive-a5; do
  [ -s "${TMP_DIR}/${a}.ndjson" ] && B_SRC="${B_SRC} ${TMP_DIR}/${a}.ndjson"
done
if [ -z "${B_SRC}" ]; then
  record_skip "B" "no archive produced by the A legs"
else
  # shellcheck disable=SC2086  # deliberate word split over the archive list
  cat ${B_SRC} > "${TMP_DIR}/mixed.ndjson"
  # A window wide enough to hold whatever "now" the run stamped.
  PERIOD=(--period-type calendar-year --from 2026-01-01 --to 2026-12-31)
  if "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent internal --confidentiality internal \
       --org-config "${ORG_CONFIG}" "${PERIOD[@]}" \
       --input "${TMP_DIR}/mixed.ndjson" --output "${TMP_DIR}/disclose-mixed.json" \
       >/dev/null 2> "${TMP_DIR}/disclose-mixed.err"; then
    python3 - "${TMP_DIR}/disclose-mixed.json" > "${TMP_DIR}/b1.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
agg = d.get("aggregate") or {}
mw = agg.get("messaging_waste")
if not mw:
    print("BAD aggregate.messaging_waste absent")
    raise SystemExit
tot = mw.get("windows_with_figure", 0)
parts = (mw.get("measured_windows", 0), mw.get("declared_windows", 0), mw.get("estimated_windows", 0))
models = sorted(mw.get("models") or [])
ok = sum(parts) == tot
print(f"{'OK' if ok else 'BAD'} measured={parts[0]} declared={parts[1]} estimated={parts[2]} "
      f"sum={sum(parts)} windows_with_figure={tot} models={','.join(models)} "
      f"schema={d.get('schema_version')}")
PY
    B1="$(cat "${TMP_DIR}/b1.txt")"
    if [ "${B1%% *}" = "OK" ]; then
      ok "three-term invariant holds — ${B1#OK }"
    else
      color_red "    FAIL: ${B1#BAD }"
      B_FAILS=$((B_FAILS + 1))
    fi
    # The declared-only shape: no unit test exercised measured_windows = 0.
    if [ -s "${TMP_DIR}/archive-a5.ndjson" ]; then
      if "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent internal --confidentiality internal \
           --org-config "${ORG_CONFIG}" "${PERIOD[@]}" \
           --input "${TMP_DIR}/archive-a5.ndjson" --output "${TMP_DIR}/disclose-decl.json" \
           >/dev/null 2>&1; then
        python3 - "${TMP_DIR}/disclose-decl.json" > "${TMP_DIR}/b2.txt" <<'PY'
import json, sys
mw = (json.load(open(sys.argv[1])).get("aggregate") or {}).get("messaging_waste") or {}
m, dcl = mw.get("measured_windows", -1), mw.get("declared_windows", -1)
good = m == 0 and dcl > 0 and mw.get("models") == ["broker_specpower"]
print(f"{'OK' if good else 'BAD'} measured_windows={m} declared_windows={dcl} models={mw.get('models')}")
PY
        B2="$(cat "${TMP_DIR}/b2.txt")"
        if [ "${B2%% *}" = "OK" ]; then
          ok "declared-only period — ${B2#OK }"
        else
          color_red "    FAIL: declared-only period wrong — ${B2#BAD }"
          B_FAILS=$((B_FAILS + 1))
        fi
      else
        color_red "    FAIL: disclose over the declared-only archive failed"
        B_FAILS=$((B_FAILS + 1))
      fi
    fi
  else
    color_red "    FAIL: disclose over the mixed archive failed: $(tail -2 "${TMP_DIR}/disclose-mixed.err")"
    B_FAILS=$((B_FAILS + 1))
  fi

  # v1.4 compatibility, the check that actually matters: an OFFICIAL v1.4
  # disclosure generated by the previous release must still verify under this
  # binary. Both new waste fields carry skip_serializing_if, so a report with
  # no declared source keeps its exact byte shape and therefore its hash.
  #
  # Regenerating from the same archive is NOT the test: SCHEMA_VERSION is
  # inside the hashed content, so a schema bump moves the hash by design (every
  # bump since v1.1 did). The compatibility promise is about READING a report
  # written before the bump.
  if [ -s "${V14_REPORT}" ]; then
    # Capture first, THEN parse: verify-hash exits non-zero whenever the overall
    # verdict is PARTIAL, which a hash-only report always is (no signature, no
    # binary attestation). Gating on the exit code would read that as a failure.
    "${PERF_SENTINEL_LOCAL_BIN}" verify-hash --report "${V14_REPORT}" \
      --no-identity-check --format json > "${TMP_DIR}/verify-v14.json" 2>&1 || true
    V14_STATUS="$(python3 -c "
import json
try:
    print(json.load(open('${TMP_DIR}/verify-v14.json'))['verifications']['content_hash']['status'])
except Exception as e:
    print(f'unparseable:{e}')" 2>/dev/null)"
    V14_SCHEMA="$(python3 -c "import json;print(json.load(open('${V14_REPORT}')).get('schema_version',''))" 2>/dev/null)"
    case "${V14_SCHEMA}" in
      *v1.4) : ;;
      *) color_red "    FAIL: ${V14_REPORT} is ${V14_SCHEMA}, not the pre-bump v1.4 report this leg needs"
         B_FAILS=$((B_FAILS + 1)) ;;
    esac
    if [ "${V14_STATUS}" = "ok" ]; then
      ok "the v1.4 disclosure written by 0.9.22 still verifies under this binary (content_hash unchanged)"
    else
      color_red "    FAIL: the v1.4 content_hash no longer verifies (status=${V14_STATUS}) — the new fields are not additive"
      B_FAILS=$((B_FAILS + 1))
    fi
  else
    note "B: ${V14_REPORT} missing, v1.4 hash compatibility not checked"
  fi

  # And nothing may be invented on a period that never had a messaging figure.
  if [ -s "${PREV_ARCHIVE}" ]; then
    # The archive starts on 2026-06-05: an official period must start on or
    # after the archive's first day (since 0.28.0) and cover at least 30 days.
    PREV_PERIOD=(--period-type custom --from 2026-06-05 --to 2026-07-04)
    if "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent official --confidentiality public \
         --org-config "${ORG_CONFIG}" "${PREV_PERIOD[@]}" \
         --input "${PREV_ARCHIVE}" --output "${TMP_DIR}/disclose-prev.json" >/dev/null 2>&1 \
       && python3 -c "
import json,sys
agg=json.load(open('${TMP_DIR}/disclose-prev.json')).get('aggregate') or {}
dw=agg.get('database_waste') or {}
sys.exit(0 if agg.get('messaging_waste') is None
         and 'declared_energy_kwh' not in dw and 'declared_windows' not in dw else 1)"; then
      ok "a bus-free period grows no messaging block and no declared_* field"
    else
      color_red "    FAIL: the new fields leaked into a period with no declared source"
      B_FAILS=$((B_FAILS + 1))
    fi
  fi

  if [ "${B_FAILS}" -eq 0 ]; then
    assert_pass "B" "disclosure v1.5 coherent: three-term invariant, declared-only shape, prior-period hash unchanged"
  else
    assert_fail "B" "${B_FAILS} disclosure check(s) failed"
  fi
fi

# =============================================================================
# Leg C: display surfaces
# =============================================================================
step "C: Broker waste on the report snapshot, the monitor Energy tab and the HTML dashboard"
start_mock >/dev/null 2>&1 || true
write_config c.toml "${BROKER_LABEL}" "" ""
if start_daemon c.toml c.log; then
  start_seeding 0.4
  C_PRESENT=0
  C_ABSENT=0
  # Flicker check: with scrape > batch cadence most windows see no fresh delta,
  # so the line must survive on remanence instead of blinking out.
  for _ in $(seq 1 15); do
    sleep 2
    msg_waste_present
    case $? in
      0) C_PRESENT=$((C_PRESENT + 1)) ;;
      1) C_ABSENT=$((C_ABSENT + 1)) ;;
      *) : ;;   # fetch flake, neither way
    esac
  done
  curl -fsS "${DAEMON_URL}/api/export/report" -o "${TMP_DIR}/c-report.json" 2>/dev/null || true

  C_FAILS=0
  # The data plane the TUI's Energy tab polls: every field the line renders.
  python3 -c "
import json,sys
mw=(json.load(open('${TMP_DIR}/c-report.json')).get('green_summary') or {}).get('messaging_waste') or {}
need=('energy_kwh','waste_kwh','messaging_waste_ratio','model')
sys.exit(0 if all(k in mw for k in need) and (mw.get('energy_kwh') or 0)>0 else 1)" 2>/dev/null \
    && ok "/api/export/report carries messaging_waste with every field the line renders" \
    || { color_red "    FAIL: /api/export/report has no usable messaging_waste"; C_FAILS=$((C_FAILS + 1)); }

  # `query monitor` is a TUI, so drive it headless in a pty against the still
  # running daemon. A render that does not surface the line SKIPs rather than
  # fails, and leg C then says so instead of claiming every surface.
  MON_OUT="${TMP_DIR}/c-monitor.txt"
  # Tab after 3s: the monitor opens on Advisor, the line lives on Energy.
  # A driver that never ran must not read as a tab that did not render:
  # blaming the wrong cause is what this leg was rewritten to stop doing.
  C_TUI="checked"
  if ! python3 "${SCRIPT_DIR}/../tui-common/pty_run.py" 9 200 50 3 "$(printf '\t')" \
      "${PERF_SENTINEL_LOCAL_BIN}" query --daemon "${DAEMON_URL}" monitor --refresh 1 \
      > "${MON_OUT}" 2>&1; then
    C_TUI="unchecked"
    record_skip "C-tui" "the pty driver failed to run, see ${MON_OUT}"
  elif grep -aqF "Broker waste" "${MON_OUT}"; then
    ok "\`query monitor\` Energy tab renders the 'Broker waste:' line"
  else
    C_TUI="unchecked"
    record_skip "C-tui" "the Energy tab did not render the line, see ${MON_OUT}; data plane proven above"
  fi

  "${PERF_SENTINEL_LOCAL_BIN}" report --input "${TMP_DIR}/c-report.json" --output "${TMP_DIR}/c-report.html" >/dev/null 2>&1 || true
  stop_daemon
  grep -qiE "broker waste|messaging_waste" "${TMP_DIR}/c-report.html" 2>/dev/null \
    && ok "the HTML dashboard carries the broker figure" \
    || { color_red "    FAIL: the HTML dashboard has no broker figure"; C_FAILS=$((C_FAILS + 1)); }
  note "C flicker: present ${C_PRESENT} / absent ${C_ABSENT} samples"
  if [ "${C_PRESENT}" -gt 0 ] && [ "${C_ABSENT}" -eq 0 ]; then
    ok "no flicker: ${C_PRESENT} consecutive samples all carried the figure"
  else
    color_red "    FAIL: the figure blinked (${C_PRESENT} present / ${C_ABSENT} absent)"
    C_FAILS=$((C_FAILS + 1))
  fi
  if [ "${C_FAILS}" -ne 0 ]; then
    assert_fail "C" "${C_FAILS} surface check(s) failed"
  elif [ "${C_TUI}" = "checked" ]; then
    assert_pass "C" "all surfaces show the broker figure, no flicker over ${C_PRESENT} samples"
  else
    assert_pass "C" "the report and the dashboard show the broker figure, no flicker over ${C_PRESENT} samples (the TUI surface was not checked, see C-tui)"
  fi
else
  assert_fail "C" "daemon did not start (see ${TMP_DIR}/c.log)"
fi

# =============================================================================
# Leg E: destination spellings (batch analyze, no daemon)
# =============================================================================
step "E: destination spellings across broker families"
python3 "${CASES_GEN}" cases "${TMP_DIR}/cases.ndjson" >/dev/null 2>&1 \
  || die "case generator failed"
if "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${TMP_DIR}/cases.ndjson" --format json \
     > "${TMP_DIR}/cases-out.json" 2>/dev/null; then
  python3 - "${TMP_DIR}/cases-out.json" > "${TMP_DIR}/e.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tpl = {}
for f in d.get("findings", []):
    if f.get("type") == "n_plus_one_messaging":
        tpl[f["service"]] = f["pattern"]["template"]
# Each case: the destination that must reach the template verbatim, and what
# must not be in it.
want = {
    "probe-c1-rabbit-named": ("rabbitmq orders.exchange", None),
    "probe-c3-pulsar-topic": ("pulsar persistent://public/default/orders", None),
    "probe-c4-amqp-uri": (None, "s3cr3t"),
    "probe-c5-ibmmq-jms": ("jms ORDERS@QM1", None),
    "probe-c6-routing-glob": ("rabbitmq logs.#", None),
}
fails = []
for svc, (exact, forbidden) in want.items():
    got = tpl.get(svc)
    if got is None:
        fails.append(f"{svc}: no n_plus_one_messaging finding")
    elif exact is not None and got != exact:
        fails.append(f"{svc}: template {got!r} != {exact!r}")
    elif forbidden is not None and forbidden in got:
        fails.append(f"{svc}: credential survived in {got!r}")
# The default exchange is a known blind spot rather than a pass/fail: the
# routing key is never read, so distinct keys share one template.
default_tpl = tpl.get("probe-c2-rabbit-default")
print("FAILS " + " | ".join(fails) if fails else "OK")
print(f"default-exchange-template {default_tpl!r}")
for svc in sorted(tpl):
    print(f"  {svc} -> {tpl[svc]!r}")
PY
  E_HEAD="$(head -1 "${TMP_DIR}/e.txt")"
  E_DEFAULT="$(sed -n '2p' "${TMP_DIR}/e.txt")"
  while IFS= read -r l; do note "E ${l#  }"; done < <(tail -n +3 "${TMP_DIR}/e.txt")
  note "E ${E_DEFAULT}"
  if [ "${E_HEAD}" = "OK" ]; then
    assert_pass "E" "5/5 destination spellings verbatim, AMQP credentials stripped, IBM MQ '@' preserved"
  else
    assert_fail "E" "${E_HEAD#FAILS }"
  fi
else
  assert_fail "E" "analyze failed on the crafted cases corpus"
fi

# =============================================================================
# Leg E2: slow messaging (batch analyze, no daemon)
# =============================================================================
step "E2: slow RabbitMQ publications"
python3 "${CASES_GEN}" slow-cases "${TMP_DIR}/slow-cases.ndjson" >/dev/null 2>&1 \
  || die "slow case generator failed"
if "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${TMP_DIR}/slow-cases.ndjson" --format json \
     > "${TMP_DIR}/slow-cases-out.json" 2>/dev/null; then
  python3 - "${TMP_DIR}/slow-cases-out.json" > "${TMP_DIR}/e2.txt" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    data = json.load(stream)
findings = [
    finding
    for finding in data["findings"]
    if finding["type"] == "slow_messaging"
    and finding["service"] == "probe-slow-rabbitmq"
]
if len(findings) != 1:
    print(f"FAILS expected one slow_messaging finding, got {len(findings)}")
elif findings[0]["pattern"]["occurrences"] != 3:
    print("FAILS expected three slow_messaging occurrences, got "
          f"{findings[0]['pattern']['occurrences']}")
else:
    print("OK")
PY
  E2_HEAD="$(head -1 "${TMP_DIR}/e2.txt")"
  if [ "${E2_HEAD}" = "OK" ]; then
    assert_pass "E2" "one slow_messaging finding for probe-slow-rabbitmq with three occurrences"
  else
    assert_fail "E2" "${E2_HEAD#FAILS }"
  fi
else
  assert_fail "E2" "analyze failed on the crafted slow-messaging corpus"
fi

# =============================================================================
# Leg F: producer link on the real capture
# =============================================================================
step "F: producer link — real astronomy capture, then the two crafted shapes"
python3 "${CASES_GEN}" shapes "${TMP_DIR}/shapes.ndjson" >/dev/null 2>&1 \
  || die "shape generator failed"

# Whole explain tree flattened to "<template>\t<link or empty>" per node, so a
# per-span verdict is checkable and not just "some node somewhere has a link".
explain_tree_links() {  # $1 = corpus, $2 = trace id
  "${PERF_SENTINEL_LOCAL_BIN}" explain --input "$1" --trace-id "$2" --format json 2>/dev/null \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
def walk(n):
    # Plain concatenation, not an f-string: the expression part would need
    # escaped quotes, which python 3.9 rejects inside an f-string.
    print((n.get("template") or "?") + "\t" + (n.get("link_trace_id") or ""))
    for c in n.get("children") or []:
        walk(c)
for r in d.get("roots") or []:
    walk(r)'
}

# Does any node in the tree carry a link? Empty output (trace absent from the
# analysis) counts as no.
explain_has_link() {  # $1 = corpus, $2 = trace id
  explain_tree_links "$1" "$2" | awk -F'\t' '$2 != "" {found=1} END {exit found?0:1}'
}

# ── F3 first: the crafted shapes, which localise any F1/F2 failure ───────────
F3_FAILS=0
f3_case() {  # $1 = trace id, $2 = label, $3 = expect-link (yes|no), $4 = template filter
  local got
  got="$(explain_tree_links "${TMP_DIR}/shapes.ndjson" "$1" | awk -F'\t' -v f="$4" 'index($1,f)>0 {print $2; exit}')"
  if [ "$3" = "yes" ] && [ -n "${got}" ]; then
    ok "F3 $2: link resolved"
  elif [ "$3" = "no" ] && [ -z "${got}" ]; then
    ok "F3 $2: no link, as required"
  else
    color_red "    FAIL: F3 $2: expected link=$3, got '${got:-<none>}'"
    F3_FAILS=$((F3_FAILS + 1))
  fi
}
f3_case 0000000000000000000000000000000b "sibling receive (the shape the real agents emit)" yes '"order"'
f3_case 0000000000000000000000000000000c "ancestor receive (must not regress)"             yes '"order"'
f3_case 0000000000000000000000000000000d "sibling started BEFORE the receive"              no  '"outbox_flush"'
f3_case 0000000000000000000000000000000d "sibling started after the receive"               yes '"order"'
f3_case 0000000000000000000000000000000e "work under an intermediate handler"              yes '"order"'
# The guard has to judge the node whose subtree is attributed, not the leaf: a
# handler already running when the delivery landed shields its children however
# late their own I/O fires.
f3_case 0000000000000000000000000000000f "I/O under a handler that PREDATES the receive"   no  '"outbox_flush"'
# Two deliveries under one parent: the nearest preceding receive wins, so the
# link must name the SECOND producer, never the first.
F3_TWO="$(explain_tree_links "${TMP_DIR}/shapes.ndjson" 00000000000000000000000000000010 \
  | awk -F'\t' 'index($1,"\"order\"")>0 {print $2; exit}')"
if [ "${F3_TWO}" = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2" ]; then
  ok "F3 two receives under one parent: the nearest preceding one wins"
else
  color_red "    FAIL: F3 two receives: expected the second producer, got '${F3_TWO:-<none>}'"
  F3_FAILS=$((F3_FAILS + 1))
fi

# Order invariance: the same spans, same ids, same start times, only the order
# the exporter serialised them in. Which receive explains a span is a question
# about start times, so payload order must not answer it. Compared as a set of
# template -> link pairs, because the tree's own node order legitimately follows
# the payload.
python3 "${CASES_GEN}" shapes-reversed "${TMP_DIR}/shapes-reversed.ndjson" >/dev/null 2>&1 \
  || die "reversed shape generator failed"
F3_ORDER_DIFFS=0
for tid in 0000000000000000000000000000000b 0000000000000000000000000000000c \
           0000000000000000000000000000000d 0000000000000000000000000000000e \
           0000000000000000000000000000000f 00000000000000000000000000000010; do
  if ! diff -q <(explain_tree_links "${TMP_DIR}/shapes.ndjson" "${tid}" | sort) \
                <(explain_tree_links "${TMP_DIR}/shapes-reversed.ndjson" "${tid}" | sort) >/dev/null 2>&1; then
    color_red "    FAIL: F3 order invariance broken on ${tid}"
    note "F3 ${tid} forward:  $(explain_tree_links "${TMP_DIR}/shapes.ndjson" "${tid}" | tr '\n' ';')"
    note "F3 ${tid} reversed: $(explain_tree_links "${TMP_DIR}/shapes-reversed.ndjson" "${tid}" | tr '\n' ';')"
    F3_ORDER_DIFFS=$((F3_ORDER_DIFFS + 1))
  fi
done
if [ "${F3_ORDER_DIFFS}" -eq 0 ]; then
  ok "F3 order invariance: all 6 shapes resolve identically with the payload reversed"
else
  F3_FAILS=$((F3_FAILS + F3_ORDER_DIFFS))
fi

if [ "${F3_FAILS}" -eq 0 ]; then
  assert_pass "F3" "7/7 crafted topologies plus order invariance on all 6 shapes: sibling and ancestor resolve, a pre-receive sibling and a pre-receive handler both stay unlinked, an intermediate handler does not break the walk, and the nearest preceding receive wins regardless of payload order"
else
  assert_fail "F3" "${F3_FAILS} crafted topology / order-invariance case(s) wrong"
fi

# ── F1/F2: the real capture ─────────────────────────────────────────────────
# Denominator note. Half the linked consumer traces in this capture are two-span
# traces whose only spans are messaging CONSUMER ones, and messaging
# classification admits PRODUCER only, so those traces carry no analyzable event
# and do not exist in the analysis at all. `explain` cannot annotate what was
# never ingested, so the rate is over the traces that ARE analyzable. Both
# numbers are reported: a drop in either is a regression.
for slice_name in clean degraded; do
  slice_path="${ASTRO_FIX}/${slice_name}-slice.ndjson"
  leg=$([ "${slice_name}" = "clean" ] && echo F1 || echo F2)
  if [ ! -s "${slice_path}" ]; then
    record_skip "${leg}" "astronomy-shop ${slice_name} fixture absent"
    continue
  fi
  python3 - "${slice_path}" > "${TMP_DIR}/f-traces-${slice_name}.txt" <<'PY'
import json, sys
out = set()
for line in open(sys.argv[1]):
    d = json.loads(line)
    for rs in d.get("resourceSpans", []):
        for ss in rs.get("scopeSpans", []):
            for sp in ss.get("spans", []):
                if sp.get("kind") == 5 and sp.get("links"):
                    out.add(sp["traceId"])
print("\n".join(sorted(out)))
PY
  F_TOTAL=0; F_ANALYZABLE=0; F_HIT=0
  while IFS= read -r tr; do
    [ -n "${tr}" ] || continue
    F_TOTAL=$((F_TOTAL + 1))
    [ -n "$(explain_tree_links "${slice_path}" "${tr}")" ] || continue
    F_ANALYZABLE=$((F_ANALYZABLE + 1))
    explain_has_link "${slice_path}" "${tr}" && F_HIT=$((F_HIT + 1))
  done < "${TMP_DIR}/f-traces-${slice_name}.txt"
  note "${leg} ${slice_name}: ${F_TOTAL} traces with a linked CONSUMER span, ${F_ANALYZABLE} of them analyzable, ${F_HIT} surface the link"
  if [ "${F_ANALYZABLE}" -eq 0 ]; then
    assert_fail "${leg}" "${F_TOTAL} linked consumer traces but none analyzable — the corpus or the ingest changed shape"
  elif [ "${F_HIT}" -eq "${F_ANALYZABLE}" ]; then
    assert_pass "${leg}" "${F_HIT}/${F_ANALYZABLE} analyzable linked consumer traces resolve the producer link on the real capture (${F_TOTAL} carry a link; the rest are CONSUMER-only and never enter the analysis)"
  else
    assert_fail "${leg}" "only ${F_HIT}/${F_ANALYZABLE} analyzable linked consumer traces resolve the link — see F3 for which topology rule broke"
  fi
done

# =============================================================================
# Report
# =============================================================================
step "Write report"
{
  echo "# ${SCENARIO}"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Binary: $(${PERF_SENTINEL_LOCAL_BIN} --version 2>/dev/null)"
  echo "Cadence: scrape ${SCRAPE_SECS}s, staleness ${STALENESS_SECS}s, trace_ttl 1000ms"
  echo "Broker cgroup: ${BROKER_LABEL} = ${BROKER_JOULES} J per ${ENERGY_INTERVAL}s (${KWH_PER_SEC} kWh/s)"
  echo "Declared cluster: 3 x m5.2xlarge (aws), region ${REGION}"
  echo
  echo "## Legs"
  echo
  echo "| leg | result |"
  echo "|-----|--------|"
  for row in "${SUMMARY[@]}"; do
    printf '| %s | %s |\n' "${row%%|*}" "${row#*|}"
  done
  echo
  if [ "${#NOTES[@]}" -gt 0 ]; then
    echo "## Notes"
    echo
    for n in "${NOTES[@]}"; do echo "- ${n}"; done
    echo
  fi
  echo "## Verdict"
  echo
  if [ "${FAILS}" -eq 0 ]; then echo "PASS"; else echo "FAIL (${FAILS} leg(s))"; fi
} > "${REPORT}"

echo
if [ "${FAILS}" -eq 0 ]; then
  color_green "${SCENARIO}: PASS — report at ${REPORT}"
  exit 0
fi
color_red "${SCENARIO}: FAIL (${FAILS} leg(s)) — report at ${REPORT}"
exit 1
