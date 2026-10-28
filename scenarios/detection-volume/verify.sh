#!/usr/bin/env bash
# detection-volume: the 0.37.0 detection ledger counts every detection of a
# finding, past the findings ring, and starts over on each daemon start.
#
# A throwaway loopback daemon (local release binary, no cluster) keeps
# `max_retained_findings = 5`. One OTLP/protobuf POST carries K traces with
# the same N+1 (service dv-planted) and FILLERS traces with an N+1 each on
# their own service, so more than 5 signatures compete for the ring.
#
#   V1 /api/detections counts the planted signature K times, on one row,
#      while the ring retains fewer than K of its detections.
#   V2 paging with limit=1 walks the same rows, so the same total.
#   V3 /api/status detection_ledger.current_day is today (UTC epoch day).
#   V4 after a restart, a new ledger_id, today carries gap = true, and the
#      planted signature is gone: the ledger is not persisted.
#   V5 the push to a fake PerfSentinelHub (POST /api/import/detections)
#      carries the planted count and a day object.
#   V6 detections added just before SIGTERM reach the fake Hub: only the
#      drain's forced push can carry them, the next regular round being a
#      minute away.
#
# On 0.36.0 the route does not exist (404) and V1 fails.
set -euo pipefail

SCENARIO="detection-volume"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
rm -f "${REPORT}"  # die() prints it, never show a previous run's verdict
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCENARIO}.XXXXXX")"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DV_DAEMON_HTTP_PORT:-14948}"
DAEMON_GRPC_PORT="${DV_DAEMON_GRPC_PORT:-14947}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
HUB_PORT="${DV_HUB_PORT:-14949}"
SOURCE_ID="dv-lab"
PLANTED="${DV_PLANTED:-12}"
FILLERS="${DV_FILLERS:-6}"
RING=5

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
[ "${FILLERS}" -ge "${RING}" ] || die "DV_FILLERS=${FILLERS}: at least ${RING} fillers, so the signatures outnumber the ring"
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
ok "under test: ${PERF_SENTINEL_LOCAL_BIN} ${BIN_VERSION}"

cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
trace_ttl_ms = 1000
max_retained_findings = ${RING}
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

# Summarizes the detection pushes: per ledger the max planted count, the
# days that arrived with a day object, and those marked gap=true.
push_summary() {
  python3 - "${TMP_DIR}/pushes.jsonl" "${SOURCE_ID}" <<'SUMPY'
import json, sys
path, source = sys.argv[1], sys.argv[2]
planted, gaps, days = {}, {}, set()
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
for line in lines:
    rec = json.loads(line)
    if not rec["path"].startswith("/api/import/detections?source_id=" + source):
        continue
    page = json.loads(rec["body"])
    led = page["ledger_id"]
    for r in page.get("counts", []):
        if r["signature"].startswith("n_plus_one_sql:dv-planted:"):
            planted[led] = max(planted.get(led, 0), r["detections"])
    for d in page.get("days", []):
        days.add((led, d["day"]))
        if d["gap"]:
            gaps.setdefault(led, set()).add(d["day"])
print(json.dumps({"planted": planted, "gaps": {k: sorted(v) for k, v in gaps.items()},
                  "days": sorted(f"{l}:{d}" for l, d in days)}))
SUMPY
}

start_daemon() {
  # A leftover daemon on the port would answer readiness for us.
  if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
    die "port ${DAEMON_HTTP_PORT} already answers, stop that daemon or set DV_DAEMON_HTTP_PORT"
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
  # SIGTERM: the graceful drain, as on a Kubernetes rollout.
  kill -TERM "${DAEMON_PID}" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "${DAEMON_PID}" 2>/dev/null || { DAEMON_PID=""; return 0; }
    sleep 0.25
  done
  die "daemon ${DAEMON_PID} still alive 10 s after SIGTERM"
}

today() { python3 -c 'import time; print(int(time.time() * 1000) // 86400000)'; }

step "Build the OTLP payload: ${PLANTED} planted N+1 traces, ${FILLERS} filler signatures"
cat > "${TMP_DIR}/build_payload.py" <<'PY'
import sys, time
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

out, planted, fillers = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
base = int(sys.argv[4]) if len(sys.argv) > 4 else 0
now = time.time_ns()

def kv(k, v):
    return common.KeyValue(key=k, value=common.AnyValue(string_value=v))

def n1_trace(tid, table):
    # One HTTP root and six SELECTs differing only by id: one n_plus_one_sql.
    trace_id = tid.to_bytes(16, "big")
    root = (1).to_bytes(8, "big")
    spans = [trace.Span(trace_id=trace_id, span_id=root, name="GET /api/" + table,
                        kind=trace.Span.SPAN_KIND_SERVER,
                        start_time_unix_nano=now, end_time_unix_nano=now + 50_000_000,
                        attributes=[kv("http.route", "/api/" + table)])]
    for i in range(6):
        start = now + (i + 1) * 1_000_000
        spans.append(trace.Span(
            trace_id=trace_id, span_id=(i + 2).to_bytes(8, "big"), parent_span_id=root,
            name="SELECT", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=start, end_time_unix_nano=start + 500_000,
            attributes=[kv("db.system", "postgresql"),
                        kv("db.statement", "SELECT * FROM %s WHERE id = %d" % (table, i + 1))]))
    return spans

def resource_spans(service, spans):
    return trace.ResourceSpans(
        resource=resource.Resource(attributes=[kv("service.name", service)]),
        scope_spans=[trace.ScopeSpans(spans=spans)])

rs = [resource_spans("dv-planted", [s for t in range(planted) for s in n1_trace(0xD0000 + base + t, "orders")])]
# Fillers after the planted traces, so the ring ends up holding them.
rs += [resource_spans("dv-filler-%d" % f, n1_trace(0xF0000 + f, "items")) for f in range(fillers)]
open(out, "wb").write(svc.ExportTraceServiceRequest(resource_spans=rs).SerializeToString())
PY
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/payload.pb" "${PLANTED}" "${FILLERS}"
ok "payload: $(wc -c < "${TMP_DIR}/payload.pb" | tr -d ' ') bytes"

start_daemon
DAY_BEFORE="$(today)"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
  -H 'Content-Type: application/x-protobuf' --data-binary @"${TMP_DIR}/payload.pb")"
[ "${CODE}" = "200" ] || die "OTLP POST answered ${CODE}"

# The planted rows plus every filler, so the walk below sees the whole batch.
read_ledger() {  # $1 = output file; prints "<http code> <planted total> <n_plus_one signatures>"
  local code
  code="$(curl -sS -o "$1" -w '%{http_code}' --max-time 10 "${DAEMON_URL}/api/detections?limit=5000")" || code="000"
  if [ "${code}" != "200" ]; then echo "${code} 0 0"; return 0; fi
  python3 - "$1" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
rows = [r for r in p["counts"] if r["signature"].startswith("n_plus_one_sql:")]
planted = sum(r["detections"] for r in rows if r["signature"].startswith("n_plus_one_sql:dv-planted:"))
print(200, planted, len({r["signature"] for r in rows}))
PY
}

step "V1 /api/detections counts every planted detection past a ring of ${RING}"
LEDGER_CODE="000"; LEDGER_PLANTED=0; LEDGER_SIGS=0
for _ in $(seq 1 40); do
  read -r LEDGER_CODE LEDGER_PLANTED LEDGER_SIGS <<< "$(read_ledger "${TMP_DIR}/page.json")"
  [ "${LEDGER_CODE}" = "200" ] || break
  [ "${LEDGER_PLANTED}" -ge "${PLANTED}" ] && [ "${LEDGER_SIGS}" -gt "${FILLERS}" ] && break
  sleep 0.5
done
[ "${LEDGER_CODE}" = "200" ] || die "V1 GET /api/detections answered ${LEDGER_CODE} (the route arrives in 0.37.0)"
# One more read after the wait: a late batch must not move the total.
sleep 2
read -r LEDGER_CODE LEDGER_PLANTED LEDGER_SIGS <<< "$(read_ledger "${TMP_DIR}/page.json")"
[ "${LEDGER_PLANTED}" = "${PLANTED}" ] \
  || die "V1 planted signature counted ${LEDGER_PLANTED} times, want ${PLANTED}"
[ "${LEDGER_SIGS}" -gt "${RING}" ] \
  || die "V1 only ${LEDGER_SIGS} n_plus_one_sql signatures, the ring of ${RING} could hold them all"
PLANTED_ROWS="$(python3 -c "
import json,sys
print(sum(1 for r in json.load(open(sys.argv[1]))['counts'] if r['signature'].startswith('n_plus_one_sql:dv-planted:')))" "${TMP_DIR}/page.json")"
[ "${PLANTED_ROWS}" = "1" ] || die "V1 planted signature on ${PLANTED_ROWS} rows, want 1 (one day, one signature)"
RETAINED="$(curl -fsS "${DAEMON_URL}/api/findings?limit=1000" | python3 -c "
import json,sys
items = json.load(sys.stdin)
items = items if isinstance(items, list) else items.get('findings', [])
print(sum(it.get('seen_count', 1) for it in items
          if it.get('finding', it).get('service') == 'dv-planted'
          and it.get('finding', it).get('type') == 'n_plus_one_sql'))")" \
  || die "V1 could not read /api/findings"
[ "${RETAINED}" -lt "${PLANTED}" ] \
  || die "V1 the ring retained ${RETAINED} planted detections, the scenario needs it to hold fewer than ${PLANTED}"
ok "planted signature: ${LEDGER_PLANTED} detections on one row, ${LEDGER_SIGS} N+1 signatures, ring retains ${RETAINED}"

step "V2 paging with limit=1 walks the same rows"
PAGED="$(python3 - "${DAEMON_URL}" "${TMP_DIR}/page.json" <<'PY'
import json, sys, urllib.parse, urllib.request
url, whole = sys.argv[1], json.load(open(sys.argv[2]))
rows, after, pages = [], None, 0
while True:
    q = {"limit": "1"}
    if after is not None:
        q["after"] = after
    with urllib.request.urlopen(url + "/api/detections?" + urllib.parse.urlencode(q), timeout=10) as r:
        p = json.load(r)
    pages += 1
    if p["ledger_id"] != whole["ledger_id"]:
        sys.exit("ledger_id changed during the walk")
    if len(p["counts"]) > 1:
        sys.exit("a limit=1 page carried %d rows" % len(p["counts"]))
    rows += [(c["day"], c["signature"], c["detections"]) for c in p["counts"]]
    after = p["next_after"]
    if after is None:
        break
    if pages > 10000:
        sys.exit("no end after 10000 pages")
want = [(c["day"], c["signature"], c["detections"]) for c in whole["counts"]]
if rows != want:
    sys.exit("paged rows differ from the single page: %d vs %d" % (len(rows), len(want)))
planted = sum(d for _, s, d in rows if s.startswith("n_plus_one_sql:dv-planted:"))
print(pages, planted)
PY
)" || die "V2 ${PAGED:-paging walk failed}"
read -r PAGES PAGED_PLANTED <<< "${PAGED}"
[ "${PAGED_PLANTED}" = "${PLANTED}" ] || die "V2 paged planted total ${PAGED_PLANTED}, want ${PLANTED}"
ok "${PAGES} pages, same rows, planted total ${PAGED_PLANTED}"

step "V3 /api/status detection_ledger.current_day is today"
curl -fsS "${DAEMON_URL}/api/status" > "${TMP_DIR}/status1.json" || die "V3 /api/status unreadable"
DAY_AFTER="$(today)"
CURRENT_DAY="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['detection_ledger']['current_day'])" "${TMP_DIR}/status1.json")" \
  || die "V3 /api/status has no detection_ledger.current_day"
# Midnight may fall between the two clocks: either side is today.
[ "${CURRENT_DAY}" = "${DAY_BEFORE}" ] || [ "${CURRENT_DAY}" = "${DAY_AFTER}" ] \
  || die "V3 current_day ${CURRENT_DAY}, want ${DAY_AFTER}"
LEDGER_1="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['detection_ledger']['ledger_id'])" "${TMP_DIR}/status1.json")"
ok "current_day ${CURRENT_DAY}, ledger ${LEDGER_1}"

step "V5 the push to the fake Hub carries the planted count"
# The detection half pushes at most once a minute.
V5_PLANTED=0
for _ in $(seq 1 100); do
  V5_PLANTED="$(push_summary | python3 -c "import json,sys; print(json.load(sys.stdin)['planted'].get(sys.argv[1], 0))" "${LEDGER_1}")"
  [ "${V5_PLANTED}" = "${PLANTED}" ] && break
  sleep 1
done
[ "${V5_PLANTED}" = "${PLANTED}" ] \
  || die "V5 the pushes of ledger ${LEDGER_1} carry ${V5_PLANTED} planted detections, want ${PLANTED} (fake Hub log: ${TMP_DIR}/pushes.jsonl)"
push_summary | python3 -c "import json,sys; s=json.load(sys.stdin); sys.exit(0 if any(x.startswith(sys.argv[1] + ':') for x in s['days']) else 1)" "${LEDGER_1}" \
  || die "V5 no day object pushed for ledger ${LEDGER_1}"
ok "push carried ${V5_PLANTED} planted detections and a day object"

step "V4 a restart opens a new ledger, today is a gap, nothing carried over"
# V6 setup: ${EXTRA} more planted detections, then SIGTERM before the next
# regular push round (at least a minute after V5's).
EXTRA=3
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/extra.pb" "${EXTRA}" 0 1000
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
  -H 'Content-Type: application/x-protobuf' --data-binary @"${TMP_DIR}/extra.pb")"
[ "${CODE}" = "200" ] || die "V6 OTLP POST answered ${CODE}"
WANT_TOTAL=$((PLANTED + EXTRA))
for _ in $(seq 1 40); do
  read -r _ NOW_PLANTED _ <<< "$(read_ledger "${TMP_DIR}/page-extra.json")"
  [ "${NOW_PLANTED}" = "${WANT_TOTAL}" ] && break
  sleep 0.25
done
[ "${NOW_PLANTED}" = "${WANT_TOTAL}" ] || die "V6 the ledger shows ${NOW_PLANTED} planted detections, want ${WANT_TOTAL}"
stop_daemon
start_daemon
curl -fsS "${DAEMON_URL}/api/status" > "${TMP_DIR}/status2.json" || die "V4 /api/status unreadable after restart"
LEDGER_2="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['detection_ledger']['ledger_id'])" "${TMP_DIR}/status2.json")" \
  || die "V4 /api/status has no detection_ledger after restart"
[ -n "${LEDGER_2}" ] && [ "${LEDGER_2}" != "${LEDGER_1}" ] || die "V4 ledger_id unchanged across the restart (${LEDGER_2})"
TODAY_2="$(today)"
V4="$(curl -fsS "${DAEMON_URL}/api/detections?limit=5000" | python3 -c "
import json,sys
p = json.load(sys.stdin)
day = p['current_day']
gap = [d['gap'] for d in p['days'] if d['day'] == day]
planted = sum(r['detections'] for r in p['counts'] if r['signature'].startswith('n_plus_one_sql:dv-planted:'))
print(day, gap[0] if gap else 'absent', planted)")" || die "V4 /api/detections unreadable after restart"
read -r DAY_2 GAP_2 PLANTED_2 <<< "${V4}"
[ "${DAY_2}" = "${TODAY_2}" ] || [ "${DAY_2}" = "${DAY_AFTER}" ] || die "V4 current_day ${DAY_2}, want ${TODAY_2}"
[ "${GAP_2}" = "True" ] || die "V4 today's gap is ${GAP_2}, want true on a new ledger's first day"
[ "${PLANTED_2}" = "0" ] || die "V4 the new ledger counts ${PLANTED_2} planted detections, want 0 (no persistence)"
ok "ledger ${LEDGER_1} -> ${LEDGER_2}, day ${DAY_2} gap=true, planted count 0"

step "V6 the drain pushed the detections added just before SIGTERM"
V6_PLANTED="$(push_summary | python3 -c "import json,sys; print(json.load(sys.stdin)['planted'].get(sys.argv[1], 0))" "${LEDGER_1}")"
[ "${V6_PLANTED}" = "${WANT_TOTAL}" ] \
  || die "V6 the fake Hub holds ${V6_PLANTED} planted detections for ledger ${LEDGER_1}, want ${WANT_TOTAL}: the drain did not push"
ok "drain push carried ${V6_PLANTED} planted detections"

{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Binary: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo ""
  echo "| id | check | result |"
  echo "|---|---|---|"
  echo "| V1 | planted N+1 counted by /api/detections, ring of ${RING} | ${LEDGER_PLANTED}/${PLANTED} on one row, ${LEDGER_SIGS} signatures, ring retains ${RETAINED} |"
  echo "| V2 | limit=1 walk | ${PAGES} pages, same rows, total ${PAGED_PLANTED} |"
  echo "| V3 | /api/status detection_ledger.current_day | ${CURRENT_DAY} (today) |"
  echo "| V4 | restart | new ledger_id, today gap=true, planted count 0 |"
  echo "| V5 | push to a fake Hub | ${V5_PLANTED}/${PLANTED} planted detections and a day object |"
  echo "| V6 | drain push at SIGTERM | ${V6_PLANTED}/${WANT_TOTAL} planted detections reached the fake Hub |"
  echo ""
  echo "Verdict: **PASS**"
} > "${REPORT}"
color_green "PASS, report at ${REPORT}"
