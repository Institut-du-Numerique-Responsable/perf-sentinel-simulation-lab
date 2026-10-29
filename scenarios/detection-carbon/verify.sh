#!/usr/bin/env bash
# detection-carbon: the 0.38.0 detection ledger carries each day's avoidable
# carbon, so the Hub can turn a count into grams.
#
# A throwaway loopback daemon (local release binary, no cluster) runs with
# green scoring on (default_region eu-west-3) and pushes to a fake
# PerfSentinelHub that records every POST.
#
#   C1 after an N+1 batch, today's day object on /api/detections carries
#      avoidable_gco2, avoidable_gco2_low, avoidable_io_ops, total_io_ops,
#      with gco2 > 0, avoidable_io_ops > 0, total >= avoidable and
#      0 <= low <= mid.
#   C2 avoidable_gco2 / avoidable_io_ops is finite and positive.
#   C3 a batch of clean traces raises total_io_ops and leaves the three
#      avoidable sums unchanged.
#   C4 the push carries the four keys on today's day object, with the API's
#      values.
#   C5 a carbon-only change resends the day: after another clean batch, a
#      later regular push carries today with the larger total_io_ops and no
#      count rows for it.
#   C6 a second run with green off has none of the four keys, in the API and
#      in the drain push.
#
# On 0.37.1 the keys do not exist and C1 fails.
set -euo pipefail

SCENARIO="detection-carbon"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
rm -f "${REPORT}"  # die() prints it, never show a previous run's verdict
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCENARIO}.XXXXXX")"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DC_DAEMON_HTTP_PORT:-14950}"
DAEMON_GRPC_PORT="${DC_DAEMON_GRPC_PORT:-14951}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
HUB_PORT="${DC_HUB_PORT:-14952}"
SOURCE_ID="dc-lab"
PLANTED="${DC_PLANTED:-3}"
CLEAN="${DC_CLEAN:-4}"
KEYS="avoidable_gco2 avoidable_gco2_low avoidable_io_ops total_io_ops"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

DAEMON_PID=""
HUB_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null
  [ -n "${HUB_PID}" ] && kill "${HUB_PID}" 2>/dev/null
  rm -rf "${TMP_DIR}"
  return 0
}
trap cleanup EXIT

step "Prerequisites"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
python3 -c 'import opentelemetry.proto' 2>/dev/null \
  || die "the OTLP payload needs opentelemetry-proto: pip install opentelemetry-proto"
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
ok "under test: ${PERF_SENTINEL_LOCAL_BIN} ${BIN_VERSION}"

write_config() {  # $1 = "green" to enable carbon scoring
  {
    [ "${1:-}" = "green" ] && printf '[green]\nenabled = true\ndefault_region = "eu-west-3"\n\n'
    cat <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
trace_ttl_ms = 1000
findings_stdout = false

# Never the operator's own ack store.
[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5

# A fake PerfSentinelHub on loopback records every push.
[daemon.hub_export]
enabled = true
endpoint = "http://127.0.0.1:${HUB_PORT}/api/import/findings"
source_id = "${SOURCE_ID}"
api_key_file = "${TMP_DIR}/hub.key"
flush_interval_secs = 1
EOF
  } > "${TMP_DIR}/daemon.toml"
}
python3 -c 'print("k" * 32)' > "${TMP_DIR}/hub.key"
chmod 600 "${TMP_DIR}/hub.key"

# Answers 200 to every import and appends {path, body} per POST to pushes.jsonl.
cat > "${TMP_DIR}/fake_hub.py" <<'HUBPY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, out = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(out, "a") as f:
            f.write(json.dumps({"path": self.path, "body": body.decode("utf-8", "replace")}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"accepted":0,"rejected":0}')
    def log_message(self, *args):
        pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
HUBPY
python3 "${TMP_DIR}/fake_hub.py" "${HUB_PORT}" "${TMP_DIR}/pushes.jsonl" &
HUB_PID=$!
disown "${HUB_PID}" 2>/dev/null || true  # no job-control notice when cleanup kills it
for _ in $(seq 1 20); do
  python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1)" "${HUB_PORT}" 2>/dev/null && break
  sleep 0.25
done

start_daemon() {
  # A leftover daemon on the port would answer readiness for us.
  if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
    die "port ${DAEMON_HTTP_PORT} already answers, stop that daemon or set DC_DAEMON_HTTP_PORT"
  fi
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" >> "${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  die "daemon not ready on ${DAEMON_URL}: $(tail -3 "${TMP_DIR}/daemon.log")"
}

stop_daemon() {
  # SIGTERM: the graceful drain, which forces one last push.
  kill -TERM "${DAEMON_PID}" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "${DAEMON_PID}" 2>/dev/null || { DAEMON_PID=""; return 0; }
    sleep 0.25
  done
  die "daemon ${DAEMON_PID} still alive 10 s after SIGTERM"
}

post() {  # $1 = payload file
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"$1")"
  [ "${code}" = "200" ] || die "OTLP POST of $(basename "$1") answered ${code}"
}

ledger_id() {
  curl -fsS "${DAEMON_URL}/api/status" | python3 -c "import json,sys; print(json.load(sys.stdin)['detection_ledger']['ledger_id'])"
}

# Today's day object on /api/detections, plus the planted detections, as JSON.
api_day() {
  curl -fsS --max-time 10 "${DAEMON_URL}/api/detections?limit=5000" | python3 -c "
import json, sys
p = json.load(sys.stdin)
day = [d for d in p['days'] if d['day'] == p['current_day']]
planted = sum(r['detections'] for r in p['counts']
              if r['day'] == p['current_day'] and r['signature'].startswith('n_plus_one_sql:dc-planted:'))
print(json.dumps({'day': day[0] if day else None, 'planted': planted}))"
}

# Every detection page of a ledger, in arrival order: the day object for $2
# (null when the page has none) and the count rows of that day.
pushed_pages() {  # $1 = ledger_id, $2 = day
  python3 - "${TMP_DIR}/pushes.jsonl" "${SOURCE_ID}" "$1" "$2" <<'PY'
import json, sys
path, source, ledger, day = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
pages = []
for line in lines:
    rec = json.loads(line)
    if not rec["path"].startswith("/api/import/detections?source_id=" + source):
        continue
    page = json.loads(rec["body"])
    if page["ledger_id"] != ledger:
        continue
    obj = [d for d in page.get("days", []) if d["day"] == day]
    pages.append({"day": obj[0] if obj else None,
                  "rows": [r for r in page.get("counts", []) if r["day"] == day]})
print(json.dumps(pages))
PY
}

step "Build the OTLP payloads: ${PLANTED} N+1 traces, ${CLEAN} clean traces per clean batch"
cat > "${TMP_DIR}/build_payload.py" <<'PY'
import sys, time
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

out, kind, n, base = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
now = time.time_ns()

def kv(k, v):
    return common.KeyValue(key=k, value=common.AnyValue(string_value=v))

def one_trace(tid, statements):
    trace_id = tid.to_bytes(16, "big")
    root = (1).to_bytes(8, "big")
    spans = [trace.Span(trace_id=trace_id, span_id=root, name="GET /api/orders",
                        kind=trace.Span.SPAN_KIND_SERVER,
                        start_time_unix_nano=now, end_time_unix_nano=now + 50_000_000,
                        attributes=[kv("http.route", "/api/orders")])]
    for i, sql in enumerate(statements):
        start = now + (i + 1) * 1_000_000
        spans.append(trace.Span(
            trace_id=trace_id, span_id=(i + 2).to_bytes(8, "big"), parent_span_id=root,
            name="SELECT", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=start, end_time_unix_nano=start + 500_000,
            attributes=[kv("db.system", "postgresql"), kv("db.statement", sql)]))
    return spans

if kind == "n1":
    # Six SELECTs differing only by id: one n_plus_one_sql per trace.
    stmts = ["SELECT * FROM orders WHERE id = %d" % (i + 1) for i in range(6)]
    service = "dc-planted"
else:
    # Two different tables, no repeat, nothing slow: no finding at all.
    stmts = ["SELECT * FROM customers WHERE region = 'eu'", "SELECT * FROM carriers WHERE active = true"]
    service = "dc-clean"
spans = [s for t in range(n) for s in one_trace(base + t, stmts)]
rs = trace.ResourceSpans(resource=resource.Resource(attributes=[kv("service.name", service)]),
                         scope_spans=[trace.ScopeSpans(spans=spans)])
open(out, "wb").write(svc.ExportTraceServiceRequest(resource_spans=[rs]).SerializeToString())
PY
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/n1.pb" n1 "${PLANTED}" $((0xC0000))
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/clean1.pb" clean "${CLEAN}" $((0xC1000))
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/clean2.pb" clean "${CLEAN}" $((0xC2000))
ok "payloads built"

write_config green
start_daemon
LEDGER_1="$(ledger_id)" || die "/api/status has no detection_ledger"
post "${TMP_DIR}/n1.pb"

step "C1 today's day object carries the four carbon keys after an N+1 batch"
DAY1="{}"
for _ in $(seq 1 40); do
  DAY1="$(api_day)" || die "C1 /api/detections unreadable"
  python3 -c "import json,sys; sys.exit(0 if json.loads(sys.argv[1])['planted'] >= int(sys.argv[2]) else 1)" "${DAY1}" "${PLANTED}" && break
  sleep 0.5
done
# One more read after the wait: a late batch must not move the sums.
sleep 2
DAY1="$(api_day)" || die "C1 /api/detections unreadable"
C1="$(python3 - "${DAY1}" "${PLANTED}" ${KEYS} <<'PY'
import json, sys
got, planted, keys = json.loads(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
if got["planted"] != planted:
    sys.exit("planted signature counted %d times today, want %d" % (got["planted"], planted))
d = got["day"]
if d is None:
    sys.exit("no day object for today")
missing = [k for k in keys if k not in d]
if missing:
    sys.exit("today's day object lacks %s (keys: %s)" % (", ".join(missing), ", ".join(sorted(d))))
mid, low, avoid, total = (d[k] for k in keys)
if not mid > 0:
    sys.exit("avoidable_gco2 = %r, want > 0" % mid)
if not avoid > 0:
    sys.exit("avoidable_io_ops = %r, want > 0" % avoid)
if not total >= avoid:
    sys.exit("total_io_ops %r < avoidable_io_ops %r" % (total, avoid))
if not 0 <= low <= mid:
    sys.exit("avoidable_gco2_low = %r, want within [0, %r]" % (low, mid))
print(mid, low, avoid, total)
PY
)" || die "C1 ${C1:-check failed} (the four keys arrive in 0.38.0)"
read -r C1_MID C1_LOW C1_AVOID C1_TOTAL <<< "${C1}"
ok "avoidable_gco2 ${C1_MID}, low ${C1_LOW}, avoidable_io_ops ${C1_AVOID}, total_io_ops ${C1_TOTAL}"

step "C2 avoidable_gco2 / avoidable_io_ops is finite and positive"
C2_RATIO="$(python3 -c "
import math, sys
r = float(sys.argv[1]) / float(sys.argv[2])
sys.exit('ratio %r' % r) if not (math.isfinite(r) and r > 0) else print('%.6g' % r)" "${C1_MID}" "${C1_AVOID}")" \
  || die "C2 ${C2_RATIO:-ratio not finite and positive}"
ok "${C2_RATIO} gCO2eq per avoidable I/O operation"

step "C3 a clean batch raises total_io_ops only"
post "${TMP_DIR}/clean1.pb"
read_total() { python3 -c "import json,sys; d=json.loads(sys.argv[1])['day']; print(d.get('total_io_ops', 0))" "$1"; }
DAY3="${DAY1}"
for _ in $(seq 1 40); do
  DAY3="$(api_day)" || die "C3 /api/detections unreadable"
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "$(read_total "${DAY3}")" "${C1_TOTAL}" && break
  sleep 0.5
done
sleep 2
DAY3="$(api_day)" || die "C3 /api/detections unreadable"
C3_TOTAL="$(python3 - "${DAY1}" "${DAY3}" <<'PY'
import json, sys
a, b = json.loads(sys.argv[1])["day"], json.loads(sys.argv[2])["day"]
for k in ("avoidable_gco2", "avoidable_gco2_low", "avoidable_io_ops"):
    if b.get(k) != a.get(k):
        sys.exit("%s moved from %r to %r on a batch with no finding" % (k, a.get(k), b.get(k)))
if not b.get("total_io_ops", 0) > a["total_io_ops"]:
    sys.exit("total_io_ops %r did not rise above %r" % (b.get("total_io_ops"), a["total_io_ops"]))
print(b["total_io_ops"])
PY
)" || die "C3 ${C3_TOTAL:-check failed}"
ok "total_io_ops ${C1_TOTAL} -> ${C3_TOTAL}, avoidable sums unchanged"

TODAY="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['day']['day'])" "${DAY3}")"

step "C4 the push carries the four keys with the API's values"
# The detection half pushes at most once a minute.
C4_PAGE=""
for _ in $(seq 1 150); do
  C4_PAGE="$(python3 - "$(pushed_pages "${LEDGER_1}" "${TODAY}")" "${DAY3}" ${KEYS} <<'PY'
import json, sys
pages, api, keys = json.loads(sys.argv[1]), json.loads(sys.argv[2])["day"], sys.argv[3:]
for i, p in enumerate(pages):
    if p["day"] is not None and all(p["day"].get(k) == api[k] for k in keys):
        print(i)
        break
PY
)"
  [ -n "${C4_PAGE}" ] && break
  sleep 1
done
[ -n "${C4_PAGE}" ] \
  || die "C4 no push of ledger ${LEDGER_1} carries today's day object with the API's four values (last pushed: $(pushed_pages "${LEDGER_1}" "${TODAY}" | python3 -c "import json,sys; p=[x['day'] for x in json.load(sys.stdin) if x['day']]; print(p[-1] if p else None)"))"
C4_AT="$(date +%s)"
ok "page ${C4_PAGE} of ledger ${LEDGER_1} carries today's four values"

step "C5 a carbon-only change resends the day at the next regular round"
PAGES_BEFORE="$(pushed_pages "${LEDGER_1}" "${TODAY}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
post "${TMP_DIR}/clean2.pb"
DAY5="${DAY3}"
for _ in $(seq 1 40); do
  DAY5="$(api_day)" || die "C5 /api/detections unreadable"
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "$(read_total "${DAY5}")" "${C3_TOTAL}" && break
  sleep 0.5
done
C5_TOTAL="$(read_total "${DAY5}")"
python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "${C5_TOTAL}" "${C3_TOTAL}" \
  || die "C5 the second clean batch left total_io_ops at ${C5_TOTAL}"
# No SIGTERM here: the drain marks today a gap, which would dirty the day on
# its own. Only the regular round, at least a minute after C4's, proves it.
C5_PAGE=""
for _ in $(seq 1 100); do
  C5_PAGE="$(python3 - "$(pushed_pages "${LEDGER_1}" "${TODAY}")" "${PAGES_BEFORE}" "${C5_TOTAL}" <<'PY'
import json, sys
pages, before, total = json.loads(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
for i, p in enumerate(pages[before:], before):
    if p["day"] is not None and p["day"].get("total_io_ops") == total:
        print(i, len(p["rows"]))
        break
PY
)"
  [ -n "${C5_PAGE}" ] && break
  sleep 1
done
C5_WAIT=$(( $(date +%s) - C4_AT ))
[ -n "${C5_PAGE}" ] \
  || die "C5 no push of ledger ${LEDGER_1} after page $((PAGES_BEFORE - 1)) carries today with total_io_ops ${C5_TOTAL} within ${C5_WAIT} s of C4: a carbon-only change did not dirty the day"
read -r C5_INDEX C5_ROWS <<< "${C5_PAGE}"
[ "${C5_ROWS}" = "0" ] || die "C5 the resend carries ${C5_ROWS} count rows for today, want 0 (no detection changed)"
ok "page ${C5_INDEX} resent today with total_io_ops ${C5_TOTAL} and 0 count rows, ${C5_WAIT} s after C4"
stop_daemon

step "C6 a run with green off has none of the four keys"
write_config
start_daemon
LEDGER_2="$(ledger_id)" || die "C6 /api/status has no detection_ledger"
post "${TMP_DIR}/n1.pb"
DAY6="{}"
for _ in $(seq 1 40); do
  DAY6="$(api_day)" || die "C6 /api/detections unreadable"
  python3 -c "import json,sys; sys.exit(0 if json.loads(sys.argv[1])['planted'] >= int(sys.argv[2]) else 1)" "${DAY6}" "${PLANTED}" && break
  sleep 0.5
done
sleep 2
DAY6="$(api_day)" || die "C6 /api/detections unreadable"
stop_daemon  # the drain pushes today's day object
C6="$(python3 - "${DAY6}" "$(pushed_pages "${LEDGER_2}" "${TODAY}")" "${PLANTED}" ${KEYS} <<'PY'
import json, sys
got, pages, planted, keys = json.loads(sys.argv[1]), json.loads(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
if got["planted"] != planted or got["day"] is None:
    sys.exit("planted counted %d times, want %d, with a day object" % (got["planted"], planted))
present = [k for k in keys if k in got["day"]]
if present:
    sys.exit("the API day object carries %s with green off" % ", ".join(present))
days = [p["day"] for p in pages if p["day"] is not None]
if not days:
    sys.exit("no push carried today's day object for the green-off ledger")
present = sorted({k for d in days for k in keys if k in d})
if present:
    sys.exit("a pushed day object carries %s with green off" % ", ".join(present))
print(len(days))
PY
)" || die "C6 ${C6:-check failed}"
ok "ledger ${LEDGER_2}: API and ${C6} pushed day object(s) without the four keys"

{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Binary: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo ""
  echo "| id | check | result |"
  echo "|---|---|---|"
  echo "| C1 | four keys on today after ${PLANTED} N+1 traces | gco2 ${C1_MID}, low ${C1_LOW}, avoidable_io_ops ${C1_AVOID}, total_io_ops ${C1_TOTAL} |"
  echo "| C2 | avoidable_gco2 / avoidable_io_ops | ${C2_RATIO} gCO2eq per op |"
  echo "| C3 | clean batch | total_io_ops ${C1_TOTAL} -> ${C3_TOTAL}, avoidable sums unchanged |"
  echo "| C4 | push carries the API's four values | page ${C4_PAGE} of ledger ${LEDGER_1} |"
  echo "| C5 | carbon-only change resent at the next regular round | total_io_ops ${C5_TOTAL}, 0 count rows, ${C5_WAIT} s after C4 |"
  echo "| C6 | green off | no key in the API nor in ${C6} pushed day object(s) |"
  echo ""
  echo "Verdict: **PASS**"
} > "${REPORT}"
color_green "PASS, report at ${REPORT}"
