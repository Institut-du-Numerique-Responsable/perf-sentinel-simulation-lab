#!/usr/bin/env bash
# card-signal: the 0.39.0 daemon signal behind the share card's threshold
# form. The reply to the detection push may carry a `watch` list; for a
# watched threshold-type signature the daemon counts, per day, the runs at or
# under the threshold as `below_threshold_passes`, and each day object gains
# `thresholds`.
#
# A throwaway loopback daemon (local release binary, no cluster) pushes to a
# fake PerfSentinelHub whose reply, and status on the detection route, a mode
# file sets. Every run first posts an N+1 on another service (the anchor), so
# the day moves and a detection push happens.
#
#   S1 run 1, the Hub replies without `watch`: 3 slow SELECTs (400 ms, over
#      a 250 ms threshold) give one slow_sql signature, the one to watch.
#   S2 run 1: 8 runs of that template at or under 250 ms after the reply
#      count nothing, in the API and in the drain push.
#   S3 run 2, the Hub replies `watch: [S1]`: the same 8 runs give today's
#      row for S1 `detections: 0`, `below_threshold_passes: 8`.
#   S4 today's `thresholds` carries the configured knobs (slow 250, fanout
#      30, chatty 25, pool 12, serialized 4) under their documented keys.
#   S5 the regular push carries the S3 row and the S4 thresholds.
#   S6 run 3 after a restart, the Hub answering 503 on the detection route:
#      the 8 runs count nothing, the list was lost with the process.
#   S7 run 3, the Hub accepts again with `watch: [S1]`: the next 8 runs give
#      `below_threshold_passes: 8` again.
#
# On 0.38.0 the reply's `watch` is ignored and S3 fails (no row for S1).
set -euo pipefail

SCENARIO="card-signal"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
rm -f "${REPORT}"  # die() prints it, never show a previous run's verdict
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCENARIO}.XXXXXX")"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${CS_DAEMON_HTTP_PORT:-14953}"
DAEMON_GRPC_PORT="${CS_DAEMON_GRPC_PORT:-14954}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
HUB_PORT="${CS_HUB_PORT:-14955}"
SOURCE_ID="cs-lab"
SLOW_MS=250
BELOW_TRACES=4   # two runs per trace, one under and one at the threshold
PASSES=$((BELOW_TRACES * 2))

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

cat > "${TMP_DIR}/daemon.toml" <<EOF
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

# Every threshold off its default, so S4 reads the config, not a constant.
[detection]
slow_query_threshold_ms = ${SLOW_MS}
max_fanout = 30
chatty_service_min_calls = 25
pool_saturation_concurrent_threshold = 12
serialized_min_sequential = 4

# A fake PerfSentinelHub on loopback records every push.
[daemon.hub_export]
enabled = true
endpoint = "http://127.0.0.1:${HUB_PORT}/api/import/findings"
source_id = "${SOURCE_ID}"
api_key_file = "${TMP_DIR}/hub.key"
flush_interval_secs = 1
EOF
python3 -c 'print("k" * 32)' > "${TMP_DIR}/hub.key"
chmod 600 "${TMP_DIR}/hub.key"

# The detection route answers mode.json's status, and its reply carries
# `watch` when mode.json names a list. Every other route answers 200. Each
# POST appends {path, status, body} to pushes.jsonl.
cat > "${TMP_DIR}/fake_hub.py" <<'HUBPY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, out, mode_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        mode = json.load(open(mode_path))
        status, reply = 200, {"accepted": 0, "rejected": 0}
        if self.path.startswith("/api/import/detections"):
            status = mode.get("status", 200)
            if mode.get("watch") is not None:
                reply["watch"] = mode["watch"]
        with open(out, "a") as f:
            f.write(json.dumps({"path": self.path, "status": status,
                                "body": body.decode("utf-8", "replace")}) + "\n")
        payload = json.dumps(reply).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *args):
        pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
HUBPY
hub_mode() {  # $1 = JSON
  printf '%s\n' "$1" > "${TMP_DIR}/mode.json"
}
hub_mode '{"status":200,"watch":null}'
python3 "${TMP_DIR}/fake_hub.py" "${HUB_PORT}" "${TMP_DIR}/pushes.jsonl" "${TMP_DIR}/mode.json" &
HUB_PID=$!
disown "${HUB_PID}" 2>/dev/null || true  # no job-control notice when cleanup kills it
for _ in $(seq 1 20); do
  python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1)" "${HUB_PORT}" 2>/dev/null && break
  sleep 0.25
done

start_daemon() {
  # A leftover daemon on the port would answer readiness for us.
  if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
    die "port ${DAEMON_HTTP_PORT} already answers, stop that daemon or set CS_DAEMON_HTTP_PORT"
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
  for _ in $(seq 1 60); do
    kill -0 "${DAEMON_PID}" 2>/dev/null || { DAEMON_PID=""; return 0; }
    sleep 0.25
  done
  die "daemon ${DAEMON_PID} still alive 15 s after SIGTERM"
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

# Today's view on /api/detections: the day object, every row of today, as JSON.
api_today() {
  curl -fsS --max-time 10 "${DAEMON_URL}/api/detections?limit=5000" | python3 -c "
import json, sys
p = json.load(sys.stdin)
day = [d for d in p['days'] if d['day'] == p['current_day']]
print(json.dumps({'day': day[0] if day else None,
                  'rows': {r['signature']: r for r in p['counts'] if r['day'] == p['current_day']}}))"
}

# Waits until today's row for signature $1 reaches $2 detections, then
# prints today's view.
wait_detections() {  # $1 = signature prefix, $2 = minimum
  local view=""
  for _ in $(seq 1 60); do
    view="$(api_today)" || { die "/api/detections unreadable"; } >&2
    python3 - "${view}" "$1" "$2" <<'PY' && { printf '%s' "${view}"; return 0; }
import json, sys
v, prefix, need = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3])
sys.exit(0 if sum(r["detections"] for s, r in v["rows"].items() if s.startswith(prefix)) >= need else 1)
PY
    sleep 0.5
  done
  { die "today never reached $2 detection(s) for $1: ${view}"; } >&2
}

# Waits for a detection push of ledger $1 that the fake Hub answered $2.
wait_push_status() {  # $1 = ledger_id, $2 = status
  for _ in $(seq 1 120); do
    python3 - "${TMP_DIR}/pushes.jsonl" "${SOURCE_ID}" "$1" "$2" <<'PY' && return 0
import json, sys
path, source, ledger, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    sys.exit(1)
for line in lines:
    rec = json.loads(line)
    if rec["path"].startswith("/api/import/detections?source_id=" + source) and rec["status"] == status \
            and json.loads(rec["body"]).get("ledger_id") == ledger:
        sys.exit(0)
sys.exit(1)
PY
    sleep 1
  done
  die "no detection push of ledger $1 answered $2 within 2 minutes"
}

# Every detection page of ledger $1: today's day object and today's rows.
pushed_pages() {  # $1 = ledger_id, $2 = day
  python3 - "${TMP_DIR}/pushes.jsonl" "${SOURCE_ID}" "$1" "$2" <<'PY'
import json, sys
path, source, ledger, day = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
pages = []
for line in open(path).read().splitlines():
    rec = json.loads(line)
    if not rec["path"].startswith("/api/import/detections?source_id=" + source):
        continue
    page = json.loads(rec["body"])
    if page["ledger_id"] != ledger:
        continue
    obj = [d for d in page.get("days", []) if d["day"] == day]
    pages.append({"status": rec["status"], "day": obj[0] if obj else None,
                  "rows": [r for r in page.get("counts", []) if r["day"] == day]})
print(json.dumps(pages))
PY
}

step "Build the OTLP payloads"
cat > "${TMP_DIR}/build_payload.py" <<'PY'
import sys, time
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

out, kind, n, base = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
now = time.time_ns()
MS = 1_000_000

def kv(k, v):
    return common.KeyValue(key=k, value=common.AnyValue(string_value=v))

def one_trace(tid, durations_ms):
    trace_id = tid.to_bytes(16, "big")
    root = (1).to_bytes(8, "big")
    total = sum(durations_ms) + len(durations_ms) + 5
    spans = [trace.Span(trace_id=trace_id, span_id=root, name="GET /api/orders",
                        kind=trace.Span.SPAN_KIND_SERVER,
                        start_time_unix_nano=now, end_time_unix_nano=now + total * MS,
                        attributes=[kv("http.route", "/api/orders")])]
    start = now + MS
    for i, ms in enumerate(durations_ms):
        spans.append(trace.Span(
            trace_id=trace_id, span_id=(i + 2).to_bytes(8, "big"), parent_span_id=root,
            name="SELECT", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=start, end_time_unix_nano=start + ms * MS,
            attributes=[kv("db.system", "postgresql"),
                        kv("db.statement", "SELECT * FROM orders WHERE id = %d" % (i + 1))]))
        start += (ms + 1) * MS
    return spans

threshold = int(sys.argv[5]) if len(sys.argv) > 5 else 250
if kind == "slow":
    # Three runs of one template over the threshold: one slow_sql per trace.
    service, shape = "cs-planted", [threshold + 150] * 3
elif kind == "below":
    # Two runs of the same template, one under and one exactly at the threshold.
    service, shape = "cs-planted", [threshold - 150, threshold]
else:
    # Six quick SELECTs differing by id on another service: one N+1, which
    # moves the day so a detection push happens.
    service, shape = "cs-anchor", [1] * 6
spans = [s for t in range(n) for s in one_trace(base + t, shape)]
rs = trace.ResourceSpans(resource=resource.Resource(attributes=[kv("service.name", service)]),
                         scope_spans=[trace.ScopeSpans(spans=spans)])
open(out, "wb").write(svc.ExportTraceServiceRequest(resource_spans=[rs]).SerializeToString())
PY
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/slow.pb" slow 1 $((0x5000)) "${SLOW_MS}"
for i in 1 2 3 4; do
  python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/below${i}.pb" below "${BELOW_TRACES}" $((0x5100 + i * 0x10)) "${SLOW_MS}"
  python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/anchor${i}.pb" anchor 1 $((0x5200 + i * 0x10))
done
ok "slow, below (${BELOW_TRACES} traces, ${PASSES} runs at or under ${SLOW_MS} ms) and anchor payloads built"

# ---------------------------------------------------------------- run 1
step "S1 run 1 (no watch): the slow SELECTs give the signature to watch"
start_daemon
LEDGER_1="$(ledger_id)" || die "/api/status has no detection_ledger"
post "${TMP_DIR}/anchor1.pb"
post "${TMP_DIR}/slow.pb"
VIEW1="$(wait_detections "slow_sql:cs-planted:" 1)"
SIG="$(python3 - "${VIEW1}" <<'PY'
import json, sys
sigs = [s for s in json.loads(sys.argv[1])["rows"] if s.startswith("slow_sql:cs-planted:")]
if len(sigs) != 1:
    sys.exit("want one slow_sql signature for cs-planted, got %s" % sigs)
print(sigs[0])
PY
)" || die "S1 ${SIG:-check failed}"
TODAY="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['day']['day'])" "${VIEW1}")"
ok "${SIG}"

step "S2 run 1: without a watch list, runs under the threshold count nothing"
wait_push_status "${LEDGER_1}" 200
post "${TMP_DIR}/below1.pb"
post "${TMP_DIR}/anchor2.pb"
VIEW2="$(wait_detections "n_plus_one_sql:cs-anchor:" 2)"
sleep 2
VIEW2="$(api_today)" || die "S2 /api/detections unreadable"
stop_daemon  # the drain pushes today
S2="$(python3 - "${VIEW2}" "$(pushed_pages "${LEDGER_1}" "${TODAY}")" <<'PY'
import json, sys
view, pages = json.loads(sys.argv[1]), json.loads(sys.argv[2])
hit = {s: r["below_threshold_passes"] for s, r in view["rows"].items() if "below_threshold_passes" in r}
if hit:
    sys.exit("the API carries below_threshold_passes with no watch list: %s" % hit)
pushed = [r for p in pages for r in p["rows"] if "below_threshold_passes" in r]
if pushed:
    sys.exit("a push carries below_threshold_passes with no watch list: %s" % pushed)
if not pages:
    sys.exit("no push of the no-watch ledger")
print(len(pages))
PY
)" || die "S2 ${S2:-check failed}"
ok "no below_threshold_passes in the API nor in ${S2} pushed page(s) of ledger ${LEDGER_1}"

# ---------------------------------------------------------------- run 2
step "S3 run 2 (watch: [S1]): runs at or under the threshold give a detections: 0 row"
hub_mode "{\"status\":200,\"watch\":[\"${SIG}\"]}"
start_daemon
LEDGER_2="$(ledger_id)" || die "/api/status has no detection_ledger"
post "${TMP_DIR}/anchor1.pb"
wait_push_status "${LEDGER_2}" 200
post "${TMP_DIR}/below2.pb"
VIEW3="{}"
for _ in $(seq 1 60); do
  VIEW3="$(api_today)" || die "S3 /api/detections unreadable"
  python3 -c "import json,sys; sys.exit(0 if sys.argv[2] in json.loads(sys.argv[1])['rows'] else 1)" "${VIEW3}" "${SIG}" && break
  sleep 0.5
done
sleep 2  # a late batch must not move the count
VIEW3="$(api_today)" || die "S3 /api/detections unreadable"
S3="$(python3 - "${VIEW3}" "${SIG}" "${PASSES}" <<'PY'
import json, sys
view, sig, passes = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3])
row = view["rows"].get(sig)
if row is None:
    sys.exit("no row for the watched signature today (rows: %s)" % sorted(view["rows"]))
if row["detections"] != 0:
    sys.exit("detections %r, want 0" % row["detections"])
if row.get("below_threshold_passes") != passes:
    sys.exit("below_threshold_passes %r, want %d (one per span at or under the threshold)"
             % (row.get("below_threshold_passes"), passes))
print(json.dumps(row, sort_keys=True))
PY
)" || die "S3 ${S3:-check failed}"
ok "${S3}"

step "S4 today's thresholds carry the configured knobs"
WANT_THRESHOLDS="{\"slow_query_threshold_ms\":${SLOW_MS},\"slow_http_threshold_ms\":${SLOW_MS},\"max_fanout\":30,\"chatty_threshold\":25,\"pool_saturation_threshold\":12,\"serialized_min_calls\":4}"
S4="$(python3 - "${VIEW3}" "${WANT_THRESHOLDS}" <<'PY'
import json, sys
day, want = json.loads(sys.argv[1])["day"], json.loads(sys.argv[2])
if day is None or "thresholds" not in day:
    sys.exit("today's day object has no thresholds: %s" % day)
if day["thresholds"] != want:
    sys.exit("thresholds %s, want %s" % (json.dumps(day["thresholds"], sort_keys=True), json.dumps(want, sort_keys=True)))
print(json.dumps(day["thresholds"], sort_keys=True))
PY
)" || die "S4 ${S4:-check failed}"
ok "${S4}"

step "S5 the regular push carries the row and the thresholds"
# The detection half pushes at most once a minute.
S5=""
for _ in $(seq 1 150); do
  S5="$(python3 - "$(pushed_pages "${LEDGER_2}" "${TODAY}")" "${SIG}" "${PASSES}" "${WANT_THRESHOLDS}" <<'PY'
import json, sys
pages, sig, passes, want = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3]), json.loads(sys.argv[4])
row_at = next((i for i, p in enumerate(pages) for r in p["rows"]
               if r["signature"] == sig and r["detections"] == 0 and r.get("below_threshold_passes") == passes), None)
day_at = next((i for i, p in enumerate(pages) if p["day"] and p["day"].get("thresholds") == want), None)
if row_at is not None and day_at is not None:
    print(row_at, day_at)
PY
)"
  [ -n "${S5}" ] && break
  sleep 1
done
[ -n "${S5}" ] || die "S5 no push of ledger ${LEDGER_2} carries ${SIG} with detections 0 and ${PASSES} passes, and today's thresholds (pages: $(pushed_pages "${LEDGER_2}" "${TODAY}"))"
read -r S5_ROW S5_DAY <<< "${S5}"
ok "page ${S5_ROW} carries the row, page ${S5_DAY} the thresholds"
stop_daemon

# ---------------------------------------------------------------- run 3
step "S6 run 3 after a restart, the Hub busy: the list is gone"
hub_mode "{\"status\":503,\"watch\":[\"${SIG}\"]}"
start_daemon
LEDGER_3="$(ledger_id)" || die "/api/status has no detection_ledger"
[ "${LEDGER_3}" != "${LEDGER_2}" ] || die "S6 the restart kept ledger ${LEDGER_2}"
post "${TMP_DIR}/anchor1.pb"
wait_push_status "${LEDGER_3}" 503
post "${TMP_DIR}/below3.pb"
post "${TMP_DIR}/anchor3.pb"
wait_detections "n_plus_one_sql:cs-anchor:" 2 >/dev/null
sleep 2
VIEW6="$(api_today)" || die "S6 /api/detections unreadable"
S6="$(python3 - "${VIEW6}" "${SIG}" <<'PY'
import json, sys
view, sig = json.loads(sys.argv[1]), sys.argv[2]
hit = {s: r for s, r in view["rows"].items() if "below_threshold_passes" in r or s == sig}
if hit:
    sys.exit("the restarted daemon counts the watched signature before any accepted reply: %s" % hit)
print(len(view["rows"]))
PY
)" || die "S6 ${S6:-check failed}"
ok "Hub reached and answered 503, ${PASSES} runs posted, no row for ${SIG}"

step "S7 run 3, the Hub accepts again: the list is back"
hub_mode "{\"status\":200,\"watch\":[\"${SIG}\"]}"
wait_push_status "${LEDGER_3}" 200
post "${TMP_DIR}/below4.pb"
VIEW7="{}"
for _ in $(seq 1 60); do
  VIEW7="$(api_today)" || die "S7 /api/detections unreadable"
  python3 -c "import json,sys; sys.exit(0 if sys.argv[2] in json.loads(sys.argv[1])['rows'] else 1)" "${VIEW7}" "${SIG}" && break
  sleep 0.5
done
sleep 2
VIEW7="$(api_today)" || die "S7 /api/detections unreadable"
S7="$(python3 - "${VIEW7}" "${SIG}" "${PASSES}" <<'PY'
import json, sys
view, sig, passes = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3])
row = view["rows"].get(sig)
if row is None or row["detections"] != 0 or row.get("below_threshold_passes") != passes:
    sys.exit("row %s, want detections 0 and below_threshold_passes %d" % (row, passes))
print(json.dumps(row, sort_keys=True))
PY
)" || die "S7 ${S7:-check failed}"
ok "${S7}"
stop_daemon

{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Binary: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo "- Watched signature: \`${SIG}\`"
  echo ""
  echo "| id | check | result |"
  echo "|---|---|---|"
  echo "| S1 | slow SELECTs over ${SLOW_MS} ms, no watch | one slow_sql signature |"
  echo "| S2 | ${PASSES} runs at or under, no watch | no below_threshold_passes in the API nor in ${S2} pushed page(s) |"
  echo "| S3 | ${PASSES} runs at or under, watch: [S1] | \`${S3}\` |"
  echo "| S4 | today's thresholds | \`${S4}\` |"
  echo "| S5 | regular push | row on page ${S5_ROW}, thresholds on page ${S5_DAY} of ledger ${LEDGER_2} |"
  echo "| S6 | restart, Hub 503 | no row for S1 after ${PASSES} runs |"
  echo "| S7 | Hub accepts with watch | \`${S7}\` |"
  echo ""
  echo "Verdict: **PASS**"
} > "${REPORT}"
color_green "PASS, report at ${REPORT}"
