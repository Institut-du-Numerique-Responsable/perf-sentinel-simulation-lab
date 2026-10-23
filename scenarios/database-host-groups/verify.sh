#!/usr/bin/env bash
# database-host-groups: gate the [[green.database_static.hosts]] and
# [[green.broker_static.hosts]] groups added in 0.33.0, hosts of different
# sizes priced from their own CPU query, each falling back to its own ceiling.
#
# The product tests the per-group arbitration against an injected clock. They
# never meet the cloud scraper fetching several probes per tick, one of them
# going silent while the others keep answering, then coming back and handing
# over a reading that reaches back over the outage. This scenario is the only
# place that happens.
#
# Legs (see README.md):
#   D1-D6 config: a group without instance_type, two groups on one cpu_query
#         (the error names the indexes and never echoes the query), hosts next
#         to a top-level nodes, under placement = "shared", next to
#         [green.alumet.database], and a section without hosts still loading.
#   G1    both groups live: model cloud_specpower, database power equal to the
#         SPECpower envelope of each group at its CPU, summed.
#   G2    the reader's query answers empty: the figure turns database_specpower
#         while the writer keeps its reading, so the power is writer live plus
#         reader ceiling, not two ceilings. The age gauge reads the silent group.
#   G3    the reader comes back: cloud_specpower again, and the energy over the
#         outage and recovery is billed once, the reader's first reading, which
#         reaches back over the outage, dropped.
#   B1    broker groups next to database groups: messaging_waste on
#         cloud_specpower, broker power equal to its groups' envelope.
#
# Self-contained: local release binary on loopback, a python stand-in for the
# Prometheus /api/v1/query endpoint answering per query from a state file, and
# NDJSON traffic on the JSON socket. No cluster, no Docker.
set -uo pipefail

SCENARIO="database-host-groups"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14618}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14619}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
PROM_PORT="${PROM_PORT:-19096}"
SOCK="${TMP_DIR}/hosts.sock"
STATE="${TMP_DIR}/prom-state.json"
REGION="eu-west-3"

# One scrape a second, so a group goes stale after 3 s (three intervals).
SCRAPE_SECS=1
STALENESS_SECS=$((SCRAPE_SECS * 3))

# Watts from the embedded SPECpower table (table_data.rs), idle and max.
# r6i.xlarge 3.7/16.6, r6i.large 1.9/8.3, m5.large 1.4/8.1 (checked at start).
WRITER_Q='avg(aws_rds_cpuutilization_average{dbinstance_identifier="orders-writer"})'
READER_Q='avg(aws_rds_cpuutilization_average{dbinstance_identifier=~"orders-reader-.*"})'
BROKER_A_Q='avg(aws_kafka_cpu_user_average{cluster="bus-a"})'
BROKER_B_Q='avg(aws_kafka_cpu_user_average{cluster="bus-b"})'
WRITER_CPU=50
READER_CPU=90
BROKER_A_CPU=40
BROKER_B_CPU=70

# Tolerance on a mean power over a measured stretch. One scoring window of lag
# at either end is about 5 percent over 20 s; the alternatives each leg must
# exclude sit 24 percent or more away.
TOL=0.12
MEASURE_SECS=20

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

FAILS=0
SUMMARY=()
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }

DAEMON_PID=""
PROM_PID=""
SEED_PID=""
cleanup() {
  [ -n "${SEED_PID}" ] && kill "${SEED_PID}" 2>/dev/null || true
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  [ -n "${PROM_PID}" ] && kill "${PROM_PID}" 2>/dev/null || true
  rm -f "${SOCK}" 2>/dev/null || true
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
TABLE="${PERF_SENTINEL_REPO_PATH}/crates/sentinel-core/src/score/cloud_energy/table_data.rs"
for row in '("r6i.xlarge", 3.7, 16.6)' '("r6i.large", 1.9, 8.3)' '("m5.large", 1.4, 8.1)'; do
  grep -qF "${row}" "${TABLE}" || die "SPECpower row ${row} moved in ${TABLE}: update the watts above"
done

# Expected powers, in watts: nodes x (idle + (max - idle) x cpu / 100).
watts() { python3 -c "print(round($1 * ($2 + ($3 - $2) * $4 / 100), 3))"; }
W_WRITER="$(watts 1 3.7 16.6 ${WRITER_CPU})"
W_READER="$(watts 2 1.9 8.3 ${READER_CPU})"
W_READER_CEIL="$(python3 -c "print(2 * 8.3)")"
W_WRITER_CEIL="$(python3 -c "print(1 * 16.6)")"
W_BROKER="$(python3 -c "print(round($(watts 1 1.4 8.1 ${BROKER_A_CPU}) + $(watts 2 1.4 8.1 ${BROKER_B_CPU}), 3))")"

# ── Prometheus stand-in ──────────────────────────────────────────────────────
# Answers /api/v1/query with one series per known query, read from STATE on
# every request so a leg can silence one query while the others keep answering.
# "empty" serves an empty vector, the shape a dead exporter series gives.
cat > "${TMP_DIR}/prom.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
state_path, port = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        if u.path != "/api/v1/query":
            self.send_response(404); self.end_headers(); return
        q = parse_qs(u.query).get("query", [""])[0]
        with open(state_path) as fh:
            state = json.load(fh)
        v = state.get(q)
        result = [] if v in (None, "empty") else [{"metric": {}, "value": [time.time(), str(v)]}]
        body = json.dumps({"status": "success", "data": {"resultType": "vector", "result": result}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY

set_cpu() {  # $1 = query, $2 = percent or "empty"
  python3 - "${STATE}" "$1" "$2" <<'PY'
import json, os, sys
path, q, v = sys.argv[1:4]
try:
    with open(path) as fh: state = json.load(fh)
except OSError:
    state = {}
state[q] = v if v == "empty" else float(v)
tmp = path + ".tmp"
with open(tmp, "w") as fh: json.dump(state, fh)
os.replace(tmp, path)
PY
}

start_prom() {
  lsof -ti "tcp:${PROM_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  python3 "${TMP_DIR}/prom.py" "${STATE}" "${PROM_PORT}" >/dev/null 2>&1 &
  PROM_PID=$!
  disown "${PROM_PID}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:${PROM_PORT}/api/v1/query?query=x" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

# ── daemon ───────────────────────────────────────────────────────────────────
free_daemon_port() {
  for p in "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}"; do
    lsof -ti "tcp:${p}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  done
}

start_daemon() {  # $1 = config basename, $2 = log basename
  free_daemon_port
  rm -f "${SOCK}"
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/$1" > "${TMP_DIR}/$2" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && break
    kill -0 "${DAEMON_PID}" 2>/dev/null || return 1
    sleep 0.5
  done
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

# $1 outfile, $2 database section body, $3 extra sections.
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

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5

[green.cloud]
prometheus_endpoint = "http://127.0.0.1:${PROM_PORT}"
scrape_interval_secs = ${SCRAPE_SECS}
default_provider = "aws"

[green.database_static]
$2
${3:-}
EOF
}

GROUPS_DB="placement = \"dedicated\"
region = \"${REGION}\"

[[green.database_static.hosts]]
nodes = 1
instance_type = \"db.r6i.xlarge\"
cpu_query = '${WRITER_Q}'

[[green.database_static.hosts]]
nodes = 2
instance_type = \"db.r6i.large\"
cpu_query = '${READER_Q}'"

# ── traffic ──────────────────────────────────────────────────────────────────
# 8 sibling SELECTs per trace clears n_plus_one_min_occurrences, so every
# window carries SQL and a database figure; MSG=1 adds 8 Kafka publishes.
cat > "${TMP_DIR}/seed.py" <<'PY'
import json, os, socket, sys, time
from datetime import datetime, timezone
sock_path, interval, msg = sys.argv[1], float(sys.argv[2]), sys.argv[3] == "1"
n = 0
while True:
    now = datetime.now(timezone.utc)
    ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
    tid = f"dhg{n:029d}"
    base = {"timestamp": ts, "trace_id": tid, "parent_span_id": "s000000000000000",
            "service": "orders-svc", "cloud_region": "eu-west-3", "duration_us": 1500,
            "source": {"endpoint": "GET /orders", "method": "OrderService::list"}}
    events = [dict(base, span_id=f"s{i:015d}", type="sql", operation="SELECT",
                   target=f"SELECT * FROM items WHERE order_id = {i}") for i in range(1, 9)]
    if msg:
        events += [dict(base, span_id=f"m{i:015d}", type="messaging", operation="kafka",
                        target="orders") for i in range(1, 9)]
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

start_seeding() {  # $1 = 1 to add messaging
  python3 "${TMP_DIR}/seed.py" "${SOCK}" 0.3 "${1:-0}" >/dev/null 2>&1 &
  SEED_PID=$!
}

# ── readers ──────────────────────────────────────────────────────────────────
metric() {  # $1 = metric name; prints its value, 0 when absent
  curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null \
    | awk -v m="$1" '$1==m {print $2; f=1} END {if(!f) print 0}'
}

waste_model() {  # $1 = database_waste|messaging_waste
  curl -fsS "${DAEMON_URL}/api/export/report" 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(((d.get("green_summary") or {}).get(sys.argv[1]) or {}).get("model", ""))' "$1" 2>/dev/null || echo ""
}

wait_model() {  # $1 = waste key, $2 = expected model, $3 = timeout s
  for _ in $(seq 1 "$3"); do
    [ "$(waste_model "$1")" = "$2" ] && return 0
    sleep 1
  done
  return 1
}

# Mean power of an in-total counter over MEASURE_SECS, in watts.
mean_watts() {  # $1 = counter name
  local c0 c1 t0 t1
  c0="$(metric "$1")"; t0="$(python3 -c 'import time; print(time.time())')"
  sleep "${MEASURE_SECS}"
  c1="$(metric "$1")"; t1="$(python3 -c 'import time; print(time.time())')"
  python3 -c "print(round(($c1 - $c0) * 3.6e6 / ($t1 - $t0), 3))"
}

within() {  # $1 = measured, $2 = expected; exit 0 when within TOL
  python3 -c "import sys; sys.exit(0 if abs($1 - $2) <= ${TOL} * $2 else 1)"
}

DB_COUNTER="perf_sentinel_scored_database_energy_kwh_total"
BROKER_COUNTER="perf_sentinel_scored_broker_energy_kwh_total"
AGE_GAUGE="perf_sentinel_database_cpu_last_scrape_age_seconds"

# ── D: config refusals ───────────────────────────────────────────────────────
# Every subcommand loads the config, so the cheap batch path checks the load.
step "D: config refusals"
printf '[]\n' > "${TMP_DIR}/empty.json"

expect_reject() {  # $1 = leg, $2 = config, $3 = substring the error must carry, $4 = substring it must not carry
  local out
  if out="$("${PERF_SENTINEL_LOCAL_BIN}" analyze --config "${TMP_DIR}/$2" --input "${TMP_DIR}/empty.json" 2>&1)"; then
    assert_fail "$1" "$2 loaded, expected a refusal naming '$3'"
    return
  fi
  if ! printf '%s' "${out}" | grep -qF -- "$3"; then
    assert_fail "$1" "$2 refused without '$3': $(printf '%s' "${out}" | head -3)"
    return
  fi
  if [ -n "${4:-}" ] && printf '%s' "${out}" | grep -qF -- "$4"; then
    assert_fail "$1" "$2 refusal echoes '$4'"
    return
  fi
  assert_pass "$1" "$2 refused: $3"
}

write_config d1.toml "placement = \"dedicated\"

[[green.database_static.hosts]]
nodes = 1
instance_type = \"db.r6i.xlarge\"

[[green.database_static.hosts]]
nodes = 2"
expect_reject D1 d1.toml "hosts[1] nodes and instance_type go together"

DUP_Q='avg(cpu{marker="dup-query-marker"})'
write_config d2.toml "placement = \"dedicated\"

[[green.database_static.hosts]]
nodes = 1
instance_type = \"db.r6i.xlarge\"
cpu_query = '${DUP_Q}'

[[green.database_static.hosts]]
nodes = 2
instance_type = \"db.r6i.large\"
cpu_query = '${DUP_Q}'"
expect_reject D2 d2.toml "hosts[0] and hosts[1] read the same cpu_query" "dup-query-marker"

write_config d3.toml "placement = \"dedicated\"
nodes = 2

[[green.database_static.hosts]]
nodes = 1
instance_type = \"db.r6i.xlarge\""
expect_reject D3 d3.toml "next to hosts"

write_config d4.toml "placement = \"shared\"
cpu_query = 'avg(pod_cpu)'

[[green.database_static.hosts]]
nodes = 1
instance_type = \"db.r6i.xlarge\""
expect_reject D4 d4.toml "placement = 'dedicated' only"

write_config d5.toml "placement = \"dedicated\"

[[green.database_static.hosts]]
nodes = 1
instance_type = \"db.r6i.xlarge\"" "[green.alumet]
endpoint = \"http://127.0.0.1:1/metrics\"
metric_name = \"energy_consumed_alumet\"
label_key = \"resource_consumer_kind\"

[green.alumet.database]
label_value = \"pg-cgroup\""
expect_reject D5 d5.toml "cannot sit next to"

write_config d6.toml "placement = \"dedicated\"
nodes = 2
instance_type = \"db.r6i.large\"
cpu_query = '${READER_Q}'"
if out="$("${PERF_SENTINEL_LOCAL_BIN}" analyze --config "${TMP_DIR}/d6.toml" --input "${TMP_DIR}/empty.json" 2>&1)"; then
  assert_pass D6 "a section without hosts still loads"
else
  assert_fail D6 "a section without hosts refused: $(printf '%s' "${out}" | head -3)"
fi

# ── G: database groups live, one silenced, recovered ────────────────────────
step "G: database groups against the cloud scraper"
set_cpu "${WRITER_Q}" "${WRITER_CPU}"
set_cpu "${READER_Q}" "${READER_CPU}"
start_prom || die "Prometheus stand-in did not start on ${PROM_PORT}"
write_config groups.toml "${GROUPS_DB}"
start_daemon groups.toml daemon-groups.log || die "daemon did not start: $(tail -5 "${TMP_DIR}/daemon-groups.log")"
start_seeding 0

EXP_G1="$(python3 -c "print(round(${W_WRITER} + ${W_READER}, 3))")"
if wait_model database_waste cloud_specpower 20; then
  sleep 3
  w="$(mean_watts "${DB_COUNTER}")"
  age="$(metric "${AGE_GAUGE}")"
  if within "${w}" "${EXP_G1}"; then
    assert_pass G1 "both groups live: cloud_specpower, ${w} W against ${EXP_G1} W expected"
  else
    assert_fail G1 "both groups live: ${w} W, expected ${EXP_G1} W (+/- ${TOL})"
  fi
  if python3 -c "import sys; sys.exit(0 if ${age} < ${STALENESS_SECS} else 1)"; then
    assert_pass G1-age "age gauge ${age} s under the ${STALENESS_SECS} s staleness while both answer"
  else
    assert_fail G1-age "age gauge ${age} s while both groups answer"
  fi
else
  assert_fail G1 "database_waste never reached cloud_specpower (last: '$(waste_model database_waste)')"
fi

EXP_G2="$(python3 -c "print(round(${W_WRITER} + ${W_READER_CEIL}, 3))")"
BOTH_CEIL="$(python3 -c "print(round(${W_WRITER_CEIL} + ${W_READER_CEIL}, 3))")"
c_cut="$(metric "${DB_COUNTER}")"; t_cut="$(python3 -c 'import time; print(time.time())')"
set_cpu "${READER_Q}" empty
if wait_model database_waste database_specpower 15; then
  sleep 2
  w="$(mean_watts "${DB_COUNTER}")"
  age="$(metric "${AGE_GAUGE}")"
  if within "${w}" "${EXP_G2}"; then
    assert_pass G2 "reader silent: database_specpower, ${w} W = writer live + reader ceiling (${EXP_G2} W), not two ceilings (${BOTH_CEIL} W)"
  else
    assert_fail G2 "reader silent: ${w} W, expected ${EXP_G2} W (two ceilings would read ${BOTH_CEIL} W)"
  fi
  if python3 -c "import sys; sys.exit(0 if ${age} > ${STALENESS_SECS} else 1)"; then
    assert_pass G2-age "age gauge ${age} s reads the silent group while the writer answers"
  else
    assert_fail G2-age "age gauge ${age} s while the reader is silent"
  fi
else
  assert_fail G2 "database_waste never turned database_specpower with the reader silent (last: '$(waste_model database_waste)')"
fi

set_cpu "${READER_Q}" "${READER_CPU}"
t_back="$(python3 -c 'import time; print(time.time())')"
if wait_model database_waste cloud_specpower 15; then
  sleep 12
  c_end="$(metric "${DB_COUNTER}")"; t_end="$(python3 -c 'import time; print(time.time())')"
  # Billed once: writer live throughout, reader ceiling over the outage, reader
  # live after it. A reader reading stacked on its ceiling adds reader live over
  # the whole outage, about a third more here.
  read -r got exp stacked <<<"$(python3 -c "
cut, back, end = ${t_cut}, ${t_back}, ${t_end}
got = (${c_end} - ${c_cut}) * 3.6e6
exp = ${W_WRITER} * (end - cut) + ${W_READER_CEIL} * (back - cut) + ${W_READER} * (end - back)
print(round(got), round(exp), round(exp + ${W_READER} * (back - cut)))")"
  if within "${got}" "${exp}"; then
    assert_pass G3 "reader back: cloud_specpower, ${got} J over the outage and recovery against ${exp} J billed once (${stacked} J stacked)"
  else
    assert_fail G3 "reader back: ${got} J, expected ${exp} J billed once (${stacked} J if stacked)"
  fi
else
  assert_fail G3 "database_waste never returned to cloud_specpower (last: '$(waste_model database_waste)')"
fi
stop_daemon

# ── B: broker groups next to database groups ─────────────────────────────────
step "B: broker groups"
set_cpu "${BROKER_A_Q}" "${BROKER_A_CPU}"
set_cpu "${BROKER_B_Q}" "${BROKER_B_CPU}"
write_config broker.toml "${GROUPS_DB}" "[green.broker_static]
placement = \"dedicated\"
region = \"${REGION}\"

[[green.broker_static.hosts]]
nodes = 1
instance_type = \"kafka.m5.large\"
cpu_query = '${BROKER_A_Q}'

[[green.broker_static.hosts]]
nodes = 2
instance_type = \"kafka.m5.large\"
cpu_query = '${BROKER_B_Q}'"
if start_daemon broker.toml daemon-broker.log; then
  start_seeding 1
  if wait_model messaging_waste cloud_specpower 20; then
    sleep 3
    w="$(mean_watts "${BROKER_COUNTER}")"
    if within "${w}" "${W_BROKER}"; then
      assert_pass B1 "broker groups live: cloud_specpower, ${w} W against ${W_BROKER} W expected"
    else
      assert_fail B1 "broker groups live: ${w} W, expected ${W_BROKER} W (+/- ${TOL})"
    fi
  else
    assert_fail B1 "messaging_waste never reached cloud_specpower (last: '$(waste_model messaging_waste)')"
  fi
  stop_daemon
else
  assert_fail B1 "daemon refused the broker groups: $(tail -5 "${TMP_DIR}/daemon-broker.log")"
fi

# ── report ───────────────────────────────────────────────────────────────────
{
  echo "# ${SCENARIO}"
  echo
  echo "Binary: $("${PERF_SENTINEL_LOCAL_BIN}" --version 2>/dev/null)"
  echo
  echo "| Leg | Result |"
  echo "|-----|--------|"
  for row in "${SUMMARY[@]}"; do echo "| ${row%%|*} | ${row#*|} |"; done
} > "${REPORT}"
cat "${REPORT}"

if [ "${FAILS}" -gt 0 ]; then
  color_red "FAILED: ${FAILS} leg(s)"
  exit 1
fi
color_green "PASS"
