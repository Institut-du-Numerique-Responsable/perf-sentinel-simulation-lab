#!/usr/bin/env bash
# alumet-db-waste: validate perf-sentinel's database-waste feature, the DB cgroup
# energy attributed to the SQL-only avoidable share, measured (0.9.13) and the
# 0.9.14 estimated fallback + disclosure v1.4 publication.
#
# 0.9.13 added, on top of the 0.9.12 Alumet backend (see alumet-conformance):
#   - green_summary.{total_sql_io_ops,avoidable_sql_io_ops}: the SQL-only slice
#     of the io-op counters (SQL spans / n_plus_one_sql+redundant_sql findings).
#   - [green.alumet.database]: declares one DB cgroup label. Each scored window
#     the daemon multiplies that cgroup's MEASURED window energy by the SQL waste
#     ratio and reports green_summary.database_waste = {energy_kwh, waste_kwh,
#     waste_gco2, region, sql_waste_ratio, model="alumet_rapl"}. A CPU-only lower
#     bound EXCLUDED from energy_kwh / co2.
#
# 0.9.14 keeps that measured path byte-for-byte and adds:
#   - an ESTIMATED fallback on every run with no [green.alumet.database] (every
#     batch `analyze`), model="estimated": a re-presented SHARE of the report
#     totals (a subset of energy_kwh/co2), never additional energy.
#   - the figure on all three surfaces: text report (`analyze`), `query monitor`
#     Energy tab, and the HTML dashboard.
#   - disclosure schema v1.4: both tiers are now PUBLISHED in `disclose` as a
#     separate labelled block (per-window disclosure_waste.database, period
#     aggregate.database_waste with a provenance split). Since 0.32.0 a
#     measured figure is INSIDE the totals as a host term, never an
#     application's (carbon_breakdown.database_kgco2eq).
#
# Self-contained: local release binary on loopback + a python http.server serving
# the committed alumet-conformance capture augmented with ONE synthetic DB-cgroup
# series carrying a known joules-per-poll value, so every figure is checkable.
# No cluster. Docker not required (traces seeded over the daemon's protobuf OTLP
# endpoint with the committed datadog-bridge N+1 fixture).
#
# Legs (see README.md):
#   B   measured database_waste end to end: present, energy_kwh>0, waste_kwh ==
#       energy_kwh * sql_waste_ratio, ratio == avoidable_sql/total_sql, gco2>0,
#       excluded from the top-level totals, and PUBLISHED in `disclose` as
#       aggregate.database_waste (models=[alumet_rapl]) yet still outside the
#       period totals (they do not move vs a database-stripped archive).
#   C   sticky live cell: no flap between scrapes, then ages out after the scraper
#       dies (TTL = 2x staleness = 6x scrape interval), not pinned forever.
#   D   carry-over under shedding: with a 1-deep analysis queue flooded to shed,
#       the DB energy summed across archived NDJSON windows is conserved and the
#       daemon sheds instead of OOMing.
#   E   config validation: collision / typo'd subsection / no-endpoint / unknown
#       key are REJECTED at load; an unknown region only WARNS (gco2 absent).
#   F   monitor line: `query monitor` Energy tab renders the "Database waste:"
#       line the /api/export/report snapshot backs.
#   G   estimated fallback on batch `analyze` (no DB config, no Alumet): the
#       database_waste figure is model="estimated", a subset of the report totals,
#       on all three surfaces (json / text `[within the report totals]` / HTML).
#   H   disclose round-trip over a mixed archive (measured + estimated):
#       aggregate.database_waste provenance split, totals unchanged, schema >= v1.4
#       (additive by contract, so the assertion is a floor and not an exact pin)
#       accepted by the official intent, content_hash round-trips fail-closed,
#       and a pre-v1.4 no-database archive stays additive (no spurious block).
#   I   provenance honesty: the estimated tag is literally "estimated", and a
#       declared-but-undelivered DB label emits nothing (no double count).
set -uo pipefail

SCENARIO="alumet-db-waste"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_PROM="${SCRIPT_DIR}/../alumet-conformance/fixtures/alumet-wire-capture.prom"
DD_FIX="${SCRIPT_DIR}/../datadog-bridge/fixtures"
ORG_CONFIG="${SCRIPT_DIR}/../disclose/fixtures/org-config.toml"
SHED_FIX="${SCRIPT_DIR}/../daemon-analysis-shedding/fixtures/shed-load.pb"   # 300 N+1 traces/POST
# Batch/disclose fixtures for the estimated-fallback legs (G/H): a SQL-heavy N+1
# trace file + the minimal green config, and a pre-v1.4 no-database archive.
GREEN_CFG="${SCRIPT_DIR}/../sci-functional-unit/fixtures/green.toml"
SQL_TRACES="${SCRIPT_DIR}/../../artifacts/fixtures/em-real-time-traces.json"
PREV14_ARCHIVE="${SCRIPT_DIR}/../disclose/fixtures/reports-thr5.ndjson"       # 0.8.2 windows, no DB
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}/mock"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14598}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14599}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
MOCK_PORT="${MOCK_PORT:-19093}"

# Scrape/energy cadence + the synthetic DB cgroup reading. Chosen so the DB
# window energy is a round 0.1 kWh per 5s scrape: 72000 J/poll / 1.0s = 72 kW,
# * 5s / 3.6e6 = 0.1 kWh. (Synthetic, like the memory-as-joules capture it rides
# on; physical realism is not the point, checkable arithmetic is.)
SCRAPE_SECS=5
ENERGY_INTERVAL=1.0
DB_LABEL="pg-cgroup"
DB_JOULES=72000
PER_SCRAPE_KWH="$(python3 -c "print(${DB_JOULES} * ${SCRAPE_SECS} / (${ENERGY_INTERVAL} * 3.6e6))")"
REGION="eu-west-3"

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

# Is a `perf-sentinel-report/vX.Y` string at least the given floor?
#
# The disclosure schema is additive by contract, so leg H's intent is "at least
# the version that introduced the database block", never "exactly that version".
# Pinning the exact string made this scenario fail the moment the product bumped
# to v1.5, which is a lab staleness rather than a product defect, the release
# gate caught it on the messaging lot.
schema_at_least() {  # $1 = schema_version string, $2 = floor like 1.4
  python3 - "$1" "$2" <<'PY'
import re, sys
m = re.search(r'/v(\d+)\.(\d+)', sys.argv[1] or "")
if not m:
    sys.exit(1)
floor = tuple(int(x) for x in sys.argv[2].split("."))
sys.exit(0 if (int(m.group(1)), int(m.group(2))) >= floor else 1)
PY
}

DAEMON_PID=""
MOCK_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  [ -n "${MOCK_PID}" ] && kill "${MOCK_PID}" 2>/dev/null || true
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -s "${BASE_PROM}" ] || die "base capture ${BASE_PROM} missing (alumet-conformance fixture)"
[ -s "${DD_FIX}/dd-bridge-nplusone.pb" ] || die "trace fixture ${DD_FIX}/dd-bridge-nplusone.pb missing"

# ── helpers ──────────────────────────────────────────────────────────────────
free_daemon_port() {
  pkill -f "perf-sentinel watch.*${TMP_DIR}/" 2>/dev/null || true
  for p in "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}"; do
    lsof -ti "tcp:${p}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  done
}

start_daemon() {  # $1 = config under TMP_DIR ; $2 = log under TMP_DIR ; returns 0 when /api/status answers
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  free_daemon_port
  sleep 1
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/$1" > "${TMP_DIR}/$2" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && return 0
    kill -0 "${DAEMON_PID}" 2>/dev/null || return 1   # process already exited (config reject)
    sleep 0.5
  done
  return 1
}

stop_daemon() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  wait "${DAEMON_PID}" 2>/dev/null || true
  DAEMON_PID=""
}

# Launch with a config expected to be REJECTED at load: the process must exit on
# its own (non-zero) within a couple of seconds and never answer /api/status.
expect_config_reject() {  # $1 = config ; $2 = log ; returns 0 when it rejected
  free_daemon_port
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/$1" > "${TMP_DIR}/$2" 2>&1 &
  local pid=$!
  sleep 2
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
    return 1   # still alive -> config was NOT rejected
  fi
  wait "${pid}" 2>/dev/null || true
  return 0
}

post_traces() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"${DD_FIX}/dd-bridge-nplusone.pb"
}

# 300-N+1-trace payload (borrowed from daemon-analysis-shedding), big eviction
# batches that overrun a small trace window + 1-deep analysis queue -> shedding.
post_shed() {
  curl -sS -o /dev/null --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"${SHED_FIX}" 2>/dev/null || true
}

alumet_success_count() {  # successful Alumet scrapes so far (from the daemon's own /metrics)
  curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null | awk '
    index($0,"perf_sentinel_alumet_scrape_total")==1 && index($0,"status=\"success\"")>0 {print int($2); f=1; exit}
    END {if(!f) print 0}'
}

# database_waste liveness on /api/export/report. Separates a real null from a
# transient loopback flake so the sticky legs never mistake a fetch error for a
# state change. Exit: 0 = present, 1 = absent (fetch + parse OK), 2 = fetch/parse failed.
db_waste_present() {
  local body
  body="$(curl -fsS "${DAEMON_URL}/api/export/report" 2>/dev/null)" || return 2
  printf '%s' "${body}" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
sys.exit(0 if ((d.get("green_summary") or {}).get("database_waste")) else 1)'
}

# POST the N+1 fixture up to N times (8s spacing keeps one batch per 5s scrape)
# and poll until green_summary.database_waste is present. Writes the report JSON
# to $1 on success.
seed_until_db_waste() {  # $1 = out file
  for _ in $(seq 1 8); do
    [ "$(post_traces)" = "200" ] || { note "trace POST failed"; return 1; }
    sleep 4
    curl -fsS "${DAEMON_URL}/api/export/report" -o "$1" 2>/dev/null || true
    if python3 -c "import json,sys; sys.exit(0 if (json.load(open('$1')).get('green_summary') or {}).get('database_waste') else 1)" 2>/dev/null; then
      return 0
    fi
    sleep 4
  done
  return 1
}

# Count archived NDJSON windows that carry report.disclosure_waste.database.
# Tolerant of a mid-write torn trailing line from the still-running daemon
# (a raw json.loads-per-line pass would abort the whole count on one bad line).
count_db_windows() {  # $1 = ndjson file (may be absent -> 0)
  python3 - "$1" <<'PY'
import json, sys
n = 0
try: fh = open(sys.argv[1])
except OSError: print(0); sys.exit()
for line in fh:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    if ((o.get("report") or {}).get("disclosure_waste") or {}).get("database"): n += 1
print(n)
PY
}

# Copy an NDJSON archive with the per-window database blocks removed
# (disclosure_waste.database + green_summary.database_waste), so disclose over
# it produces no aggregate.database_waste: the stripped baseline for the
# "totals unmoved" exclusion invariant. Also tolerant of torn lines.
strip_db_archive() {  # $1 = in ndjson ; $2 = out ndjson
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[2], "w") as w:
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line: continue
        try: o = json.loads(line)
        except Exception: continue
        rep = o.get("report") or {}
        (rep.get("disclosure_waste") or {}).pop("database", None)
        (rep.get("green_summary") or {}).pop("database_waste", None)
        w.write(json.dumps(o) + "\n")
PY
}

# Base config: green root + daemon + one DB cgroup on the frozen capture.
# $1 extra [daemon] lines (e.g. analysis_queue_capacity / archive), $2 region.
write_config() {  # $1 = outfile ; $2 = region ; $3 = extra daemon lines ; $4 = db label
  local db_label="${4:-${DB_LABEL}}"
  cat > "${TMP_DIR}/$1" <<EOF
[green]
enabled = true
default_region = "${REGION}"

[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
trace_ttl_ms = 2000
environment = "staging"
${3:-}

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5

[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom"
scrape_interval_secs = ${SCRAPE_SECS}
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}

[green.alumet.service_mappings]
"dd-bridge-shop" = "process"

[green.alumet.database]
label_value = "${db_label}"
region = "${2}"
EOF
}

# =============================================================================
# Setup: DB-augmented exposition + metric discovery
# =============================================================================
step "Setup: frozen capture + one synthetic ${DB_LABEL} cgroup row on :${MOCK_PORT}"
cp "${BASE_PROM}" "${TMP_DIR}/mock/alumet-db.prom"
cat >> "${TMP_DIR}/mock/alumet-db.prom" <<EOF
memory_usage_alumet{kind="resident",resource_consumer_id="pgcg",resource_consumer_kind="${DB_LABEL}",resource_id="",resource_kind="local_machine"} ${DB_JOULES}.0
EOF
lsof -ti "tcp:${MOCK_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
( cd "${TMP_DIR}/mock" && exec python3 -m http.server "${MOCK_PORT}" --bind 127.0.0.1 ) >/dev/null 2>&1 &
MOCK_PID=$!
disown "${MOCK_PID}" 2>/dev/null || true
for _ in $(seq 1 20); do
  curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom" >/dev/null 2>&1 || die "mock not serving on :${MOCK_PORT}"

# The DB cgroup shares the discovered per-process metric (single metric_name).
METRIC="$(python3 - "${BASE_PROM}" <<'EOF'
import re, sys, collections
c = collections.Counter()
for line in open(sys.argv[1]):
    if line.startswith('#'): continue
    m = re.match(r'^([a-zA-Z_:][a-zA-Z0-9_:]*_alumet)\{(.*)\}\s+(\S+)', line)
    if not m: continue
    name, labels, val = m.groups()
    try: v = float(val)
    except ValueError: continue
    if 'resource_consumer_kind="process"' in labels and v > 0:
        c[name] += 1
print(c.most_common(1)[0][0] if c else "")
EOF
)"
[ -n "${METRIC}" ] || die "no per-process _alumet metric discoverable in the base capture"
note "metric ${METRIC}, DB cgroup ${DB_LABEL}=${DB_JOULES} J/poll -> ${PER_SCRAPE_KWH} kWh per ${SCRAPE_SECS}s scrape"

# =============================================================================
# Leg E: config validation (fast, no traces for the reject cases)
# =============================================================================
step "E: config validation — reject collision / typo / no-endpoint / unknown key; warn on unknown region"

# E1 collision: label_value == a service_mappings value ("process").
write_config e1.toml "${REGION}" "" "process"
if expect_config_reject e1.toml e1.log && grep -qF "also appears in service_mappings" "${TMP_DIR}/e1.log"; then
  assert_pass "E-collision" "label_value colliding with service_mappings is rejected at load"
else
  assert_fail "E-collision" "collision not rejected with the expected error: $(tail -1 "${TMP_DIR}/e1.log")"
fi

# E2 typo'd subsection [green.alumet.databse] -> unknown key on [green.alumet].
cat > "${TMP_DIR}/e2.toml" <<EOF
[green]
enabled = true
default_region = "${REGION}"
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom"
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}
scrape_interval_secs = ${SCRAPE_SECS}
[green.alumet.databse]
label_value = "${DB_LABEL}"
EOF
if expect_config_reject e2.toml e2.log && grep -qiE "unknown field|databse" "${TMP_DIR}/e2.log"; then
  assert_pass "E-typo" "typo'd [green.alumet.databse] rejected by deny_unknown_fields"
else
  assert_fail "E-typo" "typo'd subsection not rejected: $(tail -1 "${TMP_DIR}/e2.log")"
fi

# E3 database section present but no [green.alumet] endpoint.
cat > "${TMP_DIR}/e3.toml" <<EOF
[green]
enabled = true
default_region = "${REGION}"
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
[green.alumet]
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}
scrape_interval_secs = ${SCRAPE_SECS}
[green.alumet.database]
label_value = "${DB_LABEL}"
EOF
if expect_config_reject e3.toml e3.log && grep -qF "endpoint is missing" "${TMP_DIR}/e3.log"; then
  assert_pass "E-noendpoint" "[green.alumet.database] without an endpoint is rejected"
else
  assert_fail "E-noendpoint" "missing-endpoint not rejected: $(tail -1 "${TMP_DIR}/e3.log")"
fi

# E4 unknown key inside [green.alumet] (the deny_unknown_fields compat break).
cat > "${TMP_DIR}/e4.toml" <<EOF
[green]
enabled = true
default_region = "${REGION}"
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom"
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}
scrape_interval_secs = ${SCRAPE_SECS}
bogus_key = true
EOF
if expect_config_reject e4.toml e4.log && grep -qiE "unknown field|bogus_key" "${TMP_DIR}/e4.log"; then
  assert_pass "E-unknownkey" "unknown key in [green.alumet] is rejected (deny_unknown_fields compat break)"
else
  assert_fail "E-unknownkey" "unknown key not rejected: $(tail -1 "${TMP_DIR}/e4.log")"
fi

# E5 unknown-but-charset-valid region -> startup WARN, daemon keeps running,
# database_waste present with waste_gco2 absent.
write_config e5.toml "eu-wets-3" "" "${DB_LABEL}"
if start_daemon e5.toml e5.log; then
  if seed_until_db_waste "${TMP_DIR}/e5-report.json"; then
    warn_ok=0
    grep -qF "not in the embedded intensity table" "${TMP_DIR}/e5.log" && warn_ok=1
    gco2_absent="$(python3 -c "import json; dw=(json.load(open('${TMP_DIR}/e5-report.json')).get('green_summary') or {}).get('database_waste') or {}; print(0 if dw.get('waste_gco2') is not None else 1)")"
    if [ "${warn_ok}" = "1" ] && [ "${gco2_absent}" = "1" ]; then
      assert_pass "E-region-warn" "unknown region warns at startup, daemon runs, database_waste present with waste_gco2 absent"
    else
      assert_fail "E-region-warn" "warn=${warn_ok} (want 1), gco2_absent=${gco2_absent} (want 1)"
    fi
  else
    assert_fail "E-region-warn" "daemon started but never produced database_waste under the unknown region"
  fi
  stop_daemon
else
  assert_fail "E-region-warn" "daemon refused to start on an unknown (charset-valid) region — should only warn"
  stop_daemon
fi

# =============================================================================
# Leg B: database_waste end to end (+ exclusion + disclose absence)
# =============================================================================
step "B: database_waste e2e (arithmetic, exclusion) + disclose absence"
write_config b.toml "${REGION}" "" "${DB_LABEL}"
cat >> "${TMP_DIR}/b.toml" <<EOF

[daemon.archive]
path = "${TMP_DIR}/archive-b.ndjson"
max_size_mb = 100
max_files = 4
EOF
if start_daemon b.toml b.log && seed_until_db_waste "${TMP_DIR}/b-report.json"; then
  python3 - "${TMP_DIR}/b-report.json" "${PER_SCRAPE_KWH}" "${DB_LABEL}" > "${TMP_DIR}/b-verdict.txt" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1])); per_scrape = float(sys.argv[2]); db_label = sys.argv[3]
gs = r.get("green_summary") or {}
dw = gs.get("database_waste") or {}
tot_sql = gs.get("total_sql_io_ops"); av_sql = gs.get("avoidable_sql_io_ops")
ek = dw.get("energy_kwh"); wk = dw.get("waste_kwh"); ratio = dw.get("sql_waste_ratio")
gco2 = dw.get("waste_gco2"); top_ek = gs.get("energy_kwh")
psk = gs.get("per_service_energy_kwh") or {}; psm = gs.get("per_service_energy_model") or {}
out = []
def chk(tag, cond, detail): out.append((tag, bool(cond), detail))
chk("present", ek is not None and ek > 0, f"energy_kwh={ek}")
exp_ratio = min(av_sql/tot_sql, 1.0) if (tot_sql and av_sql is not None) else 0.0
chk("ratio", ratio is not None and abs(ratio-exp_ratio) < 1e-9,
    f"sql_waste_ratio={ratio} == avoidable_sql/total_sql={av_sql}/{tot_sql}={exp_ratio:.6f}")
chk("waste", wk is not None and ek is not None and ratio is not None and (ek==0 or abs(wk-ek*ratio) < 1e-9*max(1,abs(ek))),
    f"waste_kwh={wk} == energy_kwh*ratio={ek}*{ratio}={ (ek or 0)*(ratio or 0):.9g}")
chk("gco2", gco2 is not None and gco2 > 0, f"waste_gco2={gco2}")
# Since 0.32.0 the measured host figure is INSIDE the totals, never an
# application's: the DB cgroup label stays out of the per-service energy maps,
# the top-level energy_kwh is the service sum plus the host kWh, the figure is
# flagged in_totals, and co2.database_gco2 carries its carbon.
svc_sum = sum(v for v in psk.values() if isinstance(v,(int,float)))
co2 = gs.get("co2") or {}
host_g = co2.get("database_gco2"); egco2 = dw.get("energy_gco2")
incl = (db_label not in psk) and (db_label not in psm) and dw.get("in_totals") is True \
    and top_ek is not None and ek is not None \
    and abs(top_ek - (svc_sum + ek)) < 1e-6*max(1.0, abs(top_ek)) \
    and host_g is not None and egco2 is not None and abs(host_g - egco2) < 1e-9*max(1.0, abs(egco2))
chk("in-totals", incl,
    f"'{db_label}' absent from per-service maps; in_totals={dw.get('in_totals')}; top energy_kwh={top_ek}==sum(service)={svc_sum}+DB {ek}; co2.database_gco2={host_g}==energy_gco2={egco2}")
# Sanity: DB energy is a positive multiple of the per-scrape reading.
mult = (ek/per_scrape) if (ek and per_scrape) else 0
chk("scale", ek is not None and per_scrape>0 and ek >= per_scrape*0.9,
    f"energy_kwh={ek} ~ {round(mult,2)}x per-scrape {per_scrape}")
allok = all(c for _,c,_ in out)
for tag,c,detail in out:
    print(f"{'OK' if c else 'NO'}\t{tag}\t{detail}")
print(f"RESULT\t{'PASS' if allok else 'FAIL'}")
EOF
  cat "${TMP_DIR}/b-verdict.txt"
  if grep -q "^RESULT	PASS" "${TMP_DIR}/b-verdict.txt"; then
    assert_pass "B-arithmetic" "database_waste present; ratio + waste_kwh recomputed; gco2>0; host energy and carbon inside the totals, never an application's"
  else
    assert_fail "B-arithmetic" "one or more database_waste checks failed (see b-verdict.txt): $(grep '^NO' "${TMP_DIR}/b-verdict.txt" | tr '\n' ';')"
  fi

  # Force a few window closes so the archive carries >=1 disclosure_waste.database
  # line, then disclose it. Since 0.32.0 the measured figure is INSIDE the
  # period totals as a host term: the block is PRESENT (tagged the measured
  # model), every window carrying it counts it in the totals, and
  # carbon_breakdown.database_kgco2eq holds its carbon. Disclosing the archive
  # again with the per-window database block stripped leaves the totals where
  # they are (the host kWh then reads as application energy), so the totals
  # never depend on the block's presence.
  for _ in 1 2 3 4; do
    post_traces >/dev/null 2>&1; sleep 3
    [ "$(count_db_windows "${TMP_DIR}/archive-b.ndjson")" -gt 0 ] && break
  done
  # Freeze a snapshot: the leg-B daemon is still writing archive-b.ndjson (leg F
  # reuses it), so disclose the FROZEN copy: full and stripped from the SAME
  # snapshot, else the two discloses could cover different window sets and the
  # totals-unmoved compare would flake on a late service-energy window.
  cp "${TMP_DIR}/archive-b.ndjson" "${TMP_DIR}/archive-b-frozen.ndjson" 2>/dev/null
  arch_dw="$(count_db_windows "${TMP_DIR}/archive-b-frozen.ndjson")"
  if [ "${arch_dw:-0}" -gt 0 ]; then
    strip_db_archive "${TMP_DIR}/archive-b-frozen.ndjson" "${TMP_DIR}/archive-b-stripped.ndjson"
    # The archive windows are written today, so the period is the current
    # calendar quarter, not a fixed one that the calendar walks out of.
    read -r B_FROM B_TO < <(python3 -c 'import datetime as d; t=d.date.today(); q=(t.month-1)//3; s=d.date(t.year,3*q+1,1); e=(d.date(t.year+(q==3),(3*q+3)%12+1,1)-d.timedelta(days=1)); print(s,e)')
    B_PERIOD=(--period-type calendar-quarter --from "${B_FROM}" --to "${B_TO}")
    if "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent internal --confidentiality internal \
         --org-config "${ORG_CONFIG}" "${B_PERIOD[@]}" \
         --input "${TMP_DIR}/archive-b-frozen.ndjson" --output "${TMP_DIR}/b-disclosure.json" \
         >/dev/null 2>"${TMP_DIR}/b-disclose.err" \
       && "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent internal --confidentiality internal \
         --org-config "${ORG_CONFIG}" "${B_PERIOD[@]}" \
         --input "${TMP_DIR}/archive-b-stripped.ndjson" --output "${TMP_DIR}/b-disclosure-stripped.json" \
         >/dev/null 2>>"${TMP_DIR}/b-disclose.err"; then
      if bout="$(python3 - "${TMP_DIR}/b-disclosure.json" "${TMP_DIR}/b-disclosure-stripped.json" <<'PY'
import json, sys
full = json.load(open(sys.argv[1])); strip = json.load(open(sys.argv[2]))
af = full.get("aggregate") or {}; asr = strip.get("aggregate") or {}
dbw = af.get("database_waste") or {}
models = dbw.get("models") or []
mw = dbw.get("measured_windows"); wf = dbw.get("windows_with_figure")
# A genuinely-missing total is a failure, not "unmoved": do not coalesce None to 0.
def close(a, b):
    if a is None or b is None: return False
    return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
checks = {
  "block present": bool(af.get("database_waste")),
  "measured tag":  ("alumet_rapl" in models) and ("estimated" not in models),
  "all measured":  mw is not None and wf is not None and mw == wf and (dbw.get("estimated_windows") or 0) == 0,
  "in totals":     (dbw.get("in_totals_windows") or 0) == wf and (dbw.get("in_totals_energy_kwh") or 0) > 0,
  "host carbon term": ((af.get("carbon_breakdown") or {}).get("database_kgco2eq") or 0) > 0,
  "energy total unmoved": close(af.get("total_energy_kwh"),  asr.get("total_energy_kwh")),
  "carbon total unmoved": close(af.get("total_carbon_kgco2eq"), asr.get("total_carbon_kgco2eq")),
  "stripped absent": not asr.get("database_waste"),
}
bad = [k for k, v in checks.items() if not v]
print("models=%s measured=%s with_figure=%s tE=%s(strip %s) tC=%s(strip %s)" % (
    models, mw, wf,
    af.get("total_energy_kwh"), asr.get("total_energy_kwh"),
    af.get("total_carbon_kgco2eq"), asr.get("total_carbon_kgco2eq")))
if bad: print("FAILED: " + ", ".join(bad)); sys.exit(1)
PY
      )"; then
        assert_pass "B-disclose-published" "aggregate.database_waste published and in the totals (${arch_dw} window(s), ${bout}), totals unchanged vs stripped"
      else
        assert_fail "B-disclose-published" "disclose publish/exclusion invariant failed (${bout})"
      fi
    else
      record_skip "B-disclose-published" "disclose over the archive failed: $(tail -1 "${TMP_DIR}/b-disclose.err")"
    fi
  else
    record_skip "B-disclose-published" "archive carried no database window to test the disclose invariant"
  fi
  # Leave the daemon up: leg F reuses it for the headless render (F stops it),
  # so there is no second daemon + reseed.
else
  assert_fail "B-arithmetic" "daemon never produced database_waste: $(tail -2 "${TMP_DIR}/b.log")"
  record_skip "B-disclose-published" "not reached"
fi

# =============================================================================
# Leg F: monitor line (data plane the TUI polls + best-effort headless render)
# =============================================================================
step "F: query monitor Energy tab renders the Database waste line"
# The report snapshot backing build_energy_lines carries every field the
# "Database waste:" line renders (waste/measured kWh, ratio, gCO2, region).
if [ -s "${TMP_DIR}/b-report.json" ] && python3 -c "
import json,sys
dw=(json.load(open('${TMP_DIR}/b-report.json')).get('green_summary') or {}).get('database_waste') or {}
sys.exit(0 if all(k in dw for k in ('waste_kwh','energy_kwh','sql_waste_ratio')) and dw.get('waste_gco2') is not None else 1)"; then
  assert_pass "F-dataplane" "/api/export/report snapshot carries the fields the Database waste line renders"
else
  assert_fail "F-dataplane" "report snapshot missing database_waste render fields"
fi
# Best-effort: drive the TUI headless in a pty against the still-running leg-B
# daemon (whose live cell still carries database_waste), no fresh daemon/reseed.
if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
  MON_OUT="${TMP_DIR}/monitor.txt"
  # Tab after 3s: the monitor opens on Advisor, the line lives on Energy.
  # A driver that never ran must not read as a tab that did not render:
  # blaming the wrong cause is what this leg was rewritten to stop doing.
  if ! python3 "${SCRIPT_DIR}/../tui-common/pty_run.py" 9 200 50 3 "$(printf '\t')" \
      "${PERF_SENTINEL_LOCAL_BIN}" query --daemon "${DAEMON_URL}" monitor --refresh 1 \
      >"${MON_OUT}" 2>&1; then
    record_skip "F-render" "the pty driver failed to run, see ${MON_OUT}"
  elif grep -aqF "Database waste" "${MON_OUT}"; then
    extra=""
    grep -aqF "host energy, in the report totals" "${MON_OUT}" && extra=" + 'host energy, in the report totals'"
    assert_pass "F-render" "query monitor Energy tab renders the 'Database waste:' line${extra}"
  else
    record_skip "F-render" "the Energy tab did not render the line, see ${MON_OUT}; data plane proven above + upstream render unit tests cover it"
  fi
else
  record_skip "F-render" "leg-B daemon not reachable for the TUI render"
fi
stop_daemon

# =============================================================================
# Leg C: sticky live cell, no flap, then age-out after the scraper dies
# =============================================================================
step "C: sticky database_waste — no flap between scrapes, ages out after scraper death"
write_config c.toml "${REGION}" "" "${DB_LABEL}"
if start_daemon c.toml c.log && seed_until_db_waste "${TMP_DIR}/c-report.json"; then
  # No flap: poll faster than the 5s scrape for ~12s while re-seeding. Every
  # poll must carry database_waste (never null on a between-scrape batch).
  flaps=0; polls=0
  for _ in $(seq 1 6); do
    post_traces >/dev/null
    for _ in 1 2; do
      db_waste_present; rc=$?
      [ "${rc}" -eq 2 ] && { sleep 1; continue; }   # transient fetch flake: don't judge
      polls=$((polls+1))
      [ "${rc}" -eq 0 ] || flaps=$((flaps+1))
      sleep 1
    done
  done
  if [ "${flaps}" -eq 0 ]; then
    assert_pass "C-noflap" "database_waste populated on all ${polls} sub-scrape polls (no flapping to null)"
  else
    assert_fail "C-noflap" "database_waste flapped to null on ${flaps}/${polls} polls between scrapes"
  fi

  # Age-out: kill the scraper's endpoint but keep TRAFFIC flowing (the sticky
  # ages inside per-batch scoring, so continued POSTs are what drive it). The
  # live cell must null within ~TTL (last fresh <= staleness 15s after kill,
  # then sticky holds <= 30s more) and not pin a dead measurement forever.
  kill "${MOCK_PID}" 2>/dev/null || true; MOCK_PID=""
  lsof -ti "tcp:${MOCK_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  aged=""; t=0
  for _ in $(seq 1 45); do
    post_traces >/dev/null 2>&1
    db_waste_present; rc=$?
    if [ "${rc}" -eq 1 ]; then aged="${t}"; break; fi   # a SUCCESSFUL fetch shows null
    sleep 2; t=$((t+2))                                 # rc 0 (present) / 2 (flake): keep waiting
  done
  if [ -n "${aged}" ] && [ "${aged}" -ge 10 ] && [ "${aged}" -le 70 ]; then
    assert_pass "C-ageout" "database_waste aged out ~${aged}s after scraper death under continued traffic (TTL 2x staleness, not pinned forever)"
  elif [ -n "${aged}" ]; then
    assert_fail "C-ageout" "database_waste nulled at ${aged}s — outside the expected [10s,70s] TTL band"
  else
    assert_fail "C-ageout" "database_waste NEVER nulled after >90s of dead-scraper traffic (dead measurement pinned forever)"
  fi
  stop_daemon
else
  assert_fail "C-noflap" "daemon never produced database_waste for the sticky test"
  record_skip "C-ageout" "not reached"
  stop_daemon
fi
# Restart a single mock for leg D. Leg C only kills the mock on its success path,
# so free the port unconditionally (covers both the killed and the still-bound
# original) and drop any stale tracked PID before binding exactly one server.
[ -n "${MOCK_PID}" ] && kill "${MOCK_PID}" 2>/dev/null || true
lsof -ti "tcp:${MOCK_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
sleep 1
( cd "${TMP_DIR}/mock" && exec python3 -m http.server "${MOCK_PORT}" --bind 127.0.0.1 ) >/dev/null 2>&1 &
MOCK_PID=$!
disown "${MOCK_PID}" 2>/dev/null || true
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom" >/dev/null 2>&1 && break; sleep 0.5; done

# =============================================================================
# Leg D: carry-over under shedding, DB energy conserved across archived windows
# =============================================================================
step "D: carry-over under shedding — energy conserved across archived NDJSON windows, no OOM"
# cap=1 analysis queue + a tiny 20-trace window: each 300-trace POST overflows
# into a big eviction batch, CPU-heavy detect+score, whole batches shed.
write_config d.toml "${REGION}" "analysis_queue_capacity = 1
max_active_traces = 20" "${DB_LABEL}"
cat >> "${TMP_DIR}/d.toml" <<EOF

[daemon.archive]
path = "${TMP_DIR}/archive-d.ndjson"
max_size_mb = 100
max_files = 8
EOF
if [ ! -s "${SHED_FIX}" ]; then
  record_skip "D-conservation" "shed-load fixture ${SHED_FIX} missing (run make fetch or check daemon-analysis-shedding)"
elif start_daemon d.toml d.log; then
  # Daemon starts fresh (cumulative energy 0), so the total successful scrapes at
  # the end == the energy banked, in per-scrape units. That is the ground truth
  # the archived DB energy is checked against.
  # Flood: concurrent injectors replaying the 300-N+1-trace payload to overrun
  # the queue. --max-time bounds each POST. A straggler reap avoids a hung wait.
  for _ in $(seq 1 8); do
    for _ in $(seq 1 4); do post_shed & done
    sleep 2
  done
  sleep 4
  pkill -f "curl.*${DAEMON_HTTP_PORT}/v1/traces" 2>/dev/null || true
  # Quiesce: stop the flood so the 1-deep queue drains and shedding subsides. The
  # scraper keeps banking DB energy (unconsumed) through this idle window.
  sleep 16
  # Controlled consume: with the daemon idle and the scraper fresh, the FIRST
  # scored batch takes ALL accumulated energy in one window (the carry-over
  # signature). A few spaced single seeds drain the pending and flush the archive
  # so the cross-window energy total lands on the measured total.
  for _ in $(seq 1 5); do post_traces >/dev/null 2>&1; sleep 4; done
  sleep 3
  SCRAPES="$(alumet_success_count)"   # total scrapes since fresh start == energy banked
  DROPS="$(grep -c 'dropping window\|dropping line' "${TMP_DIR}/d.log" 2>/dev/null)"; DROPS="${DROPS:-0}"
  SHED="$(curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null | awk '$1 ~ /^perf_sentinel_analysis_shed_batches_total/ {print $2; f=1; exit} END{if(!f)print 0}')"
  ALIVE=0; curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && ALIVE=1
  if [ -s "${TMP_DIR}/archive-d.ndjson" ]; then
    python3 - "${TMP_DIR}/archive-d.ndjson" "${PER_SCRAPE_KWH}" "${SCRAPES}" "${DROPS}" > "${TMP_DIR}/d-verdict.txt" <<'EOF'
import json, sys
path, per_scrape, scrapes, drops = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
windows = with_dw = 0; total = 0.0; maxw = 0.0; quantized_ok = True
for line in open(path):
    line = line.strip()
    if not line: continue
    try: rep = (json.loads(line).get("report") or {})   # archive wraps {report, ts}
    except Exception: continue
    windows += 1
    dw = (rep.get("green_summary") or {}).get("database_waste")
    if dw and dw.get("energy_kwh"):
        with_dw += 1; ek = dw["energy_kwh"]; total += ek; maxw = max(maxw, ek)
        mult = ek / per_scrape          # each delta is whole scrapes accumulated
        if abs(mult - round(mult)) > 0.25: quantized_ok = False
# Ground truth: every successful Alumet scrape banked exactly per_scrape kWh.
# Consumed+archived DB energy must equal that, minus what the archive writer
# dropped (documented bound) and at most one still-pending (unconsumed) scrape.
measured = scrapes * per_scrape
lo = max(0.0, (scrapes - drops - 2)) * per_scrape   # up to 2 still-pending scrapes
hi = (scrapes + 0.5) * per_scrape
print(f"windows={windows} with_db_waste={with_dw} scrapes={scrapes} archive_drops={drops}")
print(f"sum_energy_kwh={total:.6f} max_window_kwh={maxw:.6f} per_scrape={per_scrape} measured={measured:.6f}")
# Conservation: quantized, strictly positive, no energy created (<= measured),
# and none vanished beyond archive-drops + one pending window.
conserved = with_dw > 0 and total > 0 and quantized_ok and total <= hi and total >= lo and scrapes > 0
carried = maxw > per_scrape*1.5   # a window that absorbed >1 scrape (scoring shed around it)
print(f"CONSERVED={'yes' if conserved else 'no'} QUANTIZED={'yes' if quantized_ok else 'no'} CARRIED_OVER={'yes' if carried else 'no'}")
print("RESULT", "PASS" if conserved else "FAIL")
EOF
    cat "${TMP_DIR}/d-verdict.txt"
    CARRY="$(grep -o 'CARRIED_OVER=[a-z]*' "${TMP_DIR}/d-verdict.txt" | cut -d= -f2)"
    note "D: shed_batches=${SHED}, alive=${ALIVE}, scrapes=${SCRAPES}, archive_drops=${DROPS}, carry_over=${CARRY}"
    if [ "${SHED}" -gt 0 ] && [ "${ALIVE}" = "1" ] && grep -q "^RESULT PASS" "${TMP_DIR}/d-verdict.txt"; then
      assert_pass "D-conservation" "sheds ${SHED} batches without OOM; archived DB energy == ${SCRAPES} scrapes' worth (drops=${DROPS}, carry_over=${CARRY})"
    elif [ "${ALIVE}" != "1" ]; then
      assert_fail "D-conservation" "daemon not alive after the flood — OOM/crash instead of shedding (regression)"
    elif [ "${SHED}" -eq 0 ]; then
      assert_fail "D-conservation" "no batches shed (cap=1 + 20-trace window flood did not overrun) — cannot exercise carry-over"
    else
      assert_fail "D-conservation" "DB energy not conserved vs ${SCRAPES} scrapes (drops=${DROPS}): $(grep '^sum_energy' "${TMP_DIR}/d-verdict.txt")"
    fi
  else
    assert_fail "D-conservation" "no archive written (shed=${SHED}, alive=${ALIVE})"
  fi
  stop_daemon
else
  assert_fail "D-conservation" "daemon (D) not ready: $(tail -2 "${TMP_DIR}/d.log")"
fi

# =============================================================================
# Leg G: estimated fallback on batch analyze (no [green.alumet.database], no mock)
# =============================================================================
step "G: estimated database_waste on batch analyze — json + text + html surfaces"
if [ -s "${SQL_TRACES}" ] && [ -s "${GREEN_CFG}" ]; then
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${SQL_TRACES}" --config "${GREEN_CFG}" --format json \
    > "${TMP_DIR}/g-analyze.json" 2>"${TMP_DIR}/g-analyze.err" || true
  # G-json: model=="estimated", energy_kwh>0, and a subset of the report totals
  # (a re-presented share, never additional energy).
  if gout="$(python3 - "${TMP_DIR}/g-analyze.json" <<'PY'
import json, sys
gs = json.load(open(sys.argv[1])).get("green_summary") or {}
dw = gs.get("database_waste") or {}
model = dw.get("model"); ek = dw.get("energy_kwh"); tot = gs.get("energy_kwh")
ok = (model == "estimated") and (ek is not None and ek > 0) \
    and (tot is not None and ek <= tot + 1e-12)
print("model=%s energy_kwh=%s report_total=%s" % (model, ek, tot))
sys.exit(0 if ok else 1)
PY
  )"; then
    assert_pass "G-json" "batch analyze emits database_waste model=estimated, subset of totals (${gout})"
  else
    assert_fail "G-json" "estimated database_waste json check failed (${gout:-analyze/parse error})"
  fi

  # G-text: the default text report carries a "Database waste:" line tagged
  # `model estimated` with the `[within the report totals]` scope, inverted vs
  # the measured `[host energy, in the report totals]` scope (color is off on
  # a non-tty).
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${SQL_TRACES}" --config "${GREEN_CFG}" \
    > "${TMP_DIR}/g-report.txt" 2>/dev/null || true
  gline="$(grep -a "Database waste:" "${TMP_DIR}/g-report.txt" | head -1)"
  if printf '%s' "${gline}" | grep -qF "model estimated" \
     && printf '%s' "${gline}" | grep -qF "within the report totals" \
     && ! printf '%s' "${gline}" | grep -qF "host energy, in the report totals"; then
    assert_pass "G-text" "text report Database waste line: model estimated + [within the report totals] (scope inverted vs measured)"
  else
    assert_fail "G-text" "text Database waste line missing estimated/within-totals scope: ${gline:-<no line>}"
  fi

  # G-html: the HTML dashboard's green panel renders a Database waste card whose
  # scope reads "within the report totals" for the estimated model, through
  # wasteScope() since 0.32.0.
  # The dashboard is a JS SPA: it ships a greenCard("Database waste", ...) builder
  # whose subtitle picks the scope from the embedded report's model. Assert the
  # card builder AND the estimated-scope branch are co-located (within ~600 chars,
  # not merely somewhere in the document: a far-away legend must not satisfy it).
  # This is a static surface presence check. The actual RENDERED scope is
  # data-driven and proven by G-json (model=="estimated") + G-text.
  if "${PERF_SENTINEL_LOCAL_BIN}" report --input "${SQL_TRACES}" --config "${GREEN_CFG}" \
       --output "${TMP_DIR}/g-report.html" >/dev/null 2>"${TMP_DIR}/g-html.err" \
     && [ -s "${TMP_DIR}/g-report.html" ] \
     && python3 - "${TMP_DIR}/g-report.html" <<'PY'
import sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# Every occurrence, not the first: the method-sheet glossary entry names
# the card 95 KB before the builder does, and anchoring on it made this
# check unreachable rather than red. Since 0.32.0 the card's subtitle calls
# wasteScope(), which holds the estimated-scope wording, so the builder must
# sit next to that call and wasteScope() must carry the wording.
i, ok = h.find("Database waste"), False
while i != -1 and not ok:
    ok = "wasteScope(dbw)" in h[max(0, i - 600):i + 600]
    i = h.find("Database waste", i + 1)
j = h.find("function wasteScope(")
ok = ok and j != -1 and "within the report totals" in h[j:j + 400]
sys.exit(0 if ok else 1)
PY
  then
    assert_pass "G-html" "HTML dashboard ships the Database waste card builder with the within-the-report-totals scope co-located ($(wc -c < "${TMP_DIR}/g-report.html" | tr -d ' ') bytes)"
  else
    record_skip "G-html" "report did not surface the Database waste card with the estimated scope (data plane proven by G-json/G-text): $(tail -1 "${TMP_DIR}/g-html.err" 2>/dev/null)"
  fi
else
  record_skip "G-json" "SQL traces fixture or green config missing (${SQL_TRACES})"
  record_skip "G-text" "not reached"
  record_skip "G-html" "not reached"
fi

# =============================================================================
# Leg H: disclose v1.4 round-trip, provenance split over measured + estimated
# =============================================================================
step "H: disclose >= v1.4 — aggregate.database_waste provenance (measured + estimated), hash, additive"
# Estimated archived windows: a fresh daemon with green enabled but NO
# [green.alumet.database] and no Alumet: the estimated fallback path, which
# still writes disclosure_waste.database (model estimated) per scored window.
cat > "${TMP_DIR}/h-est.toml" <<EOF
[green]
enabled = true
default_region = "${REGION}"

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

[daemon.archive]
path = "${TMP_DIR}/archive-h-est.ndjson"
max_size_mb = 100
max_files = 4
EOF
h_est_ok=0
if start_daemon h-est.toml h-est.log; then
  for _ in $(seq 1 6); do post_traces >/dev/null 2>&1; sleep 3; done
  stop_daemon
  [ "$(count_db_windows "${TMP_DIR}/archive-h-est.ndjson")" -gt 0 ] && h_est_ok=1
fi
# archive-b's MEASURED windows are the other half of the mix. Leg B can record a
# benign SKIP (no measured database window archived) while leaving archive-b
# non-empty, so gate leg H on measured windows actually being present, a
# missing-measured condition then SKIPs here too rather than hard-failing the
# both-models / measured>0 assertions on a condition leg B itself excused.
b_meas="$(count_db_windows "${TMP_DIR}/archive-b.ndjson")"

if [ "${h_est_ok}" = "1" ] && [ "${b_meas:-0}" -gt 0 ]; then
  # Mixed archive = leg B's MEASURED windows + the ESTIMATED windows above.
  cat "${TMP_DIR}/archive-b.ndjson" "${TMP_DIR}/archive-h-est.ndjson" > "${TMP_DIR}/mixed.ndjson"
  strip_db_archive "${TMP_DIR}/mixed.ndjson" "${TMP_DIR}/mixed-stripped.ndjson"
  H_PERIOD=(--period-type calendar-year --from 2026-01-01 --to 2026-12-31)
  if "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent internal --confidentiality internal \
       --org-config "${ORG_CONFIG}" "${H_PERIOD[@]}" \
       --input "${TMP_DIR}/mixed.ndjson" --output "${TMP_DIR}/h-disc.json" >/dev/null 2>"${TMP_DIR}/h.err" \
     && "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent internal --confidentiality internal \
       --org-config "${ORG_CONFIG}" "${H_PERIOD[@]}" \
       --input "${TMP_DIR}/mixed-stripped.ndjson" --output "${TMP_DIR}/h-disc-stripped.json" >/dev/null 2>>"${TMP_DIR}/h.err"; then
    if hout="$(python3 - "${TMP_DIR}/h-disc.json" "${TMP_DIR}/h-disc-stripped.json" <<'PY'
import json, sys
full = json.load(open(sys.argv[1])); strip = json.load(open(sys.argv[2]))
sv = full.get("schema_version") or ""
af = full.get("aggregate") or {}; asr = strip.get("aggregate") or {}
dbw = af.get("database_waste") or {}
models = set(dbw.get("models") or [])
mw = dbw.get("measured_windows"); ew = dbw.get("estimated_windows"); wf = dbw.get("windows_with_figure")
# A genuinely-missing total is a failure, not "unmoved": do not coalesce None to 0.
def close(a, b):
    if a is None or b is None: return False
    return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
def _schema_at_least(v, floor):
    import re
    m = re.search(r"/v(\d+)\.(\d+)", v or "")
    return bool(m) and (int(m.group(1)), int(m.group(2))) >= floor
checks = {
  # Additive by contract, so the floor is what matters, not the exact string.
  "schema >= v1.4":    _schema_at_least(sv, (1, 4)),
  "block present":     bool(af.get("database_waste")),
  "provenance sums":   mw is not None and ew is not None and wf is not None and mw + ew == wf,
  "both models":       models == {"alumet_rapl", "estimated"},
  "measured>0":        (mw or 0) > 0,
  "estimated>0":       (ew or 0) > 0,
  "totals unmoved":    close(af.get("total_energy_kwh"), asr.get("total_energy_kwh")) and close(af.get("total_carbon_kgco2eq"), asr.get("total_carbon_kgco2eq")),
  "stripped absent":   not asr.get("database_waste"),
}
bad = [k for k, v in checks.items() if not v]
print("schema=%s models=%s measured=%s estimated=%s with_figure=%s tE=%s(strip %s)" % (
    sv, sorted(models), mw, ew, wf, af.get("total_energy_kwh"), asr.get("total_energy_kwh")))
if bad: print("FAILED: " + ", ".join(bad)); sys.exit(1)
PY
    )"; then
      assert_pass "H-aggregate" "aggregate.database_waste provenance split, totals unmoved (${hout})"
    else
      assert_fail "H-aggregate" "provenance/exclusion invariant failed (${hout})"
    fi
  else
    record_skip "H-aggregate" "disclose over the mixed archive failed: $(tail -1 "${TMP_DIR}/h.err")"
  fi
else
  record_skip "H-aggregate" "no measured (archive-b=${b_meas:-0}) and/or estimated (h_est_ok=${h_est_ok}) database windows to mix"
fi

# H-schema-intent + H-additive + H-hash on a pre-v1.4 archive with NO database
# fields (reports-thr5, binary 0.8.2): the official intent must accept the v1.4
# schema, the block must stay absent (skip_serializing_if), and the content hash
# round-trips fail-closed.
# The archive starts on 2026-06-05: an official period must start on or
# after the archive's first day (since 0.28.0) and cover at least 30 days.
PREV_PERIOD=(--period-type custom --from 2026-06-05 --to 2026-07-04)
if [ -s "${PREV14_ARCHIVE}" ] && "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent official --confidentiality public \
     --org-config "${ORG_CONFIG}" "${PREV_PERIOD[@]}" \
     --input "${PREV14_ARCHIVE}" --output "${TMP_DIR}/h-official.json" >/dev/null 2>"${TMP_DIR}/h-off.err"; then
  sv="$(python3 -c "import json;print(json.load(open('${TMP_DIR}/h-official.json')).get('schema_version'))" 2>/dev/null)"
  if schema_at_least "${sv}" 1.4; then
    assert_pass "H-schema-intent" "official-intent disclose accepts and stamps ${sv} (>= v1.4, the floor that introduced the database block)"
  else
    assert_fail "H-schema-intent" "schema_version ${sv:-<none>} is below the v1.4 floor"
  fi
  if python3 -c "import json,sys; sys.exit(0 if not ((json.load(open('${TMP_DIR}/h-official.json')).get('aggregate') or {}).get('database_waste')) else 1)"; then
    assert_pass "H-additive" "pre-v1.4 no-database archive discloses without a database_waste block (additive-only fields)"
  else
    assert_fail "H-additive" "pre-v1.4 archive produced a spurious aggregate.database_waste block"
  fi
  # Capture verify-hash output first (|| true), THEN parse, verify-hash exits
  # non-zero (2 = PARTIAL under --no-identity-check), which would trip pipefail
  # and append the fallback if the status were extracted inside the same pipe.
  vh="$("${PERF_SENTINEL_LOCAL_BIN}" verify-hash --report "${TMP_DIR}/h-official.json" --no-identity-check --format json 2>/dev/null || true)"
  vh_ok="$(printf '%s' "${vh}" | python3 -c "import sys,json; print(json.load(sys.stdin)['verifications']['content_hash']['status'])" 2>/dev/null || echo unknown)"
  python3 -c "import json; r=json.load(open('${TMP_DIR}/h-official.json')); r['aggregate']['total_carbon_kgco2eq']=(r['aggregate'].get('total_carbon_kgco2eq') or 0)+1.0; json.dump(r,open('${TMP_DIR}/h-official-tampered.json','w'))" 2>/dev/null || true
  vh_t="$("${PERF_SENTINEL_LOCAL_BIN}" verify-hash --report "${TMP_DIR}/h-official-tampered.json" --no-identity-check --format json 2>/dev/null || true)"
  vh_bad="$(printf '%s' "${vh_t}" | python3 -c "import sys,json; print(json.load(sys.stdin)['verifications']['content_hash']['status'])" 2>/dev/null || echo unknown)"
  if [ "${vh_ok}" = "ok" ] && [ "${vh_bad}" = "fail" ]; then
    assert_pass "H-hash" "content_hash ok on untampered, fail on tampered (v1.4 round-trip fail-closed)"
  else
    assert_fail "H-hash" "content_hash untampered=${vh_ok} (want ok), tampered=${vh_bad} (want fail)"
  fi
else
  record_skip "H-schema-intent" "official disclose over the pre-v1.4 archive failed: $(tail -1 "${TMP_DIR}/h-off.err" 2>/dev/null)"
  record_skip "H-additive" "not reached"
  record_skip "H-hash" "not reached"
fi

# =============================================================================
# Leg I: provenance honesty (regression)
# =============================================================================
step "I: provenance — estimated tag is literal, declared-but-undelivered emits nothing"
# I-tag: every estimated archived window tags model exactly "estimated" (never a
# leaked measured tag like alumet_rapl). Gate on the SAME "estimated windows
# present" condition leg H uses (h_est_ok), so the no-estimated-data case SKIPs
# here too instead of hard-failing with a misleading "non-estimated tag" message.
if [ "${h_est_ok}" = "1" ]; then
  if itag="$(python3 - "${TMP_DIR}/archive-h-est.ndjson" <<'PY'
import json, sys
n = 0; bad = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    d = ((json.loads(line).get("report") or {}).get("disclosure_waste") or {}).get("database")
    if not d: continue
    n += 1
    if d.get("model") != "estimated": bad.append(d.get("model"))
print("%d estimated window(s), non-estimated tags: %s" % (n, bad or "none"))
sys.exit(0 if n > 0 and not bad else 1)
PY
  )"; then
    assert_pass "I-tag" "every estimated window tags model=\"estimated\" literally (${itag})"
  else
    assert_fail "I-tag" "an estimated window carried a non-estimated model tag (${itag})"
  fi
else
  record_skip "I-tag" "no estimated archive from leg H to check the tag"
fi
# I-undelivered: [green.alumet.database] declared but the labelled cgroup is never
# delivered by the scraper: the daemon must emit NO database_waste (energy carries
# over; there is no estimated fallback when a database IS declared). The leg-D mock
# is still bound and serves only the real pg-cgroup label.
if [ -n "${MOCK_PID}" ] || lsof -ti "tcp:${MOCK_PORT}" >/dev/null 2>&1; then
  write_config i.toml "${REGION}" "" "undelivered-cgroup"
  if start_daemon i.toml i.log; then
    # Watch as long as leg B needs to first observe the figure (~60s) so a
    # slowly-appearing leaked fallback cannot slip past a short window, and
    # require at least one SUCCESSFUL absent fetch (rc==1), treating rc==2
    # (fetch/parse flake) as confirmed-absence would PASS on a broken export.
    leaked=0; seen_absent=0
    for _ in $(seq 1 12); do
      post_traces >/dev/null 2>&1; sleep 4
      db_waste_present; rc=$?
      [ "${rc}" -eq 0 ] && { leaked=1; break; }             # present -> invariant broke
      [ "${rc}" -eq 1 ] && seen_absent=$((seen_absent + 1))  # fetched OK, genuinely absent
    done
    stop_daemon
    if [ "${leaked}" = "1" ]; then
      assert_fail "I-undelivered" "database_waste appeared for an undelivered DB label — estimated fallback or double count leaked in"
    elif [ "${seen_absent}" -gt 0 ]; then
      assert_pass "I-undelivered" "declared-but-undelivered DB label emits no database_waste over ${seen_absent} confirmed poll(s) (no measured figure, no estimated fallback)"
    else
      record_skip "I-undelivered" "no /api/export/report fetch succeeded to confirm absence (all polls flaked)"
    fi
  else
    record_skip "I-undelivered" "daemon did not start for the undelivered-label config: $(tail -1 "${TMP_DIR}/i.log")"
  fi
else
  record_skip "I-undelivered" "Alumet mock not running to back the endpoint for the undelivered-label config"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel database-waste feature: 0.9.13 measured (Alumet DB cgroup energy x SQL waste ratio) + 0.9.14 estimated fallback and disclosure v1.4 publication."
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
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
