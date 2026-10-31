#!/usr/bin/env bash
# hub-card: PerfSentinelHub 0.10.0 share cards, end to end, from a 0.39.0
# daemon's push to a card file the engine verifies offline.
#
# A local PerfSentinelHub process (a Release build, no cluster, no Docker)
# knows two sources. hcd-lab is fed by a real local daemon through a recording
# proxy, which keeps every answer to the detection push. hcd-week stands for
# the daemon that watched the same service over the two closed ISO weeks
# before this one: its ledger pages are imported with its own key. The Hub
# restarts three times on the same database.
#
#   H0 cards off: every card route is a 404, /api/status carries no `cards`.
#   H1 the daemon's N+1 and slow SELECT reach the Hub; a done action freezes
#      the finding (frozen_finding_json, schema V20).
#   H2 C1 end to end: after a restart the daemon's first push answer carries
#      `watch` with the done slow signature only, the daemon then counts 8
#      passes under the threshold on a `detections: 0` row, pushes it, the Hub
#      stores it and its windowed read still counts the one detection. The
#      week source's own push answer watches nothing.
#   H3 a closed week with a confirmed fix: options name the fix with its
#      volume before, the signed scope leaves the late daemon out, and the
#      week recap names it in `late_sources`.
#   H4 a story card in png, svg, jxl and pdf: each file passes
#      `perf-sentinel verify-card` offline, content intact, figures as signed.
#   H5 the key: one made by the first card, its DNS line; a rotation and a
#      revocation change the list, the DNS lines and what verify-card --keys
#      says of the first card.
#   H6 past Hub:Cards:MaxConcurrentRenders (1) a render is a 503 with
#      Retry-After: 5.
#   H7 detection days outlive the 180-day finding retention (1,100 days by
#      default) and a shorter Hub:DetectionRetention purges them at boot.
#   H8 under access control a reader (no cards.write) gets 403, a member reads
#      the options, may not manage the key, and the attachment check is a 409
#      without Hub:Cards:Domain. No network call is ever made.
#
# What is forged: hcd-week's ledger pages (two sealed weeks, the planted N+1
# counted until the day before the fix, with carbon), and, with the Hub
# stopped, the done date of the N+1 action, moved into last week by one SQL
# UPDATE. No route sets a done date in the past. Everything else, the finding,
# its frozen envelope, the watch list, the passes, the cards and the keys, is
# the daemon's, the Hub's and the engine's own.
set -euo pipefail

SCENARIO="hub-card"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
rm -f "${REPORT}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCENARIO}.XXXXXX")"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
PERF_SENTINEL_HUB_REPO_PATH="${PERF_SENTINEL_HUB_REPO_PATH:-${HOME}/RiderProjects/PerfSentinelHub}"
HUB_DLL="${PERF_SENTINEL_HUB_DLL:-${PERF_SENTINEL_HUB_REPO_PATH}/PerfSentinelHub/bin/Release/net10.0/PerfSentinelHub.dll}"
BASE_PORT="${HCD_BASE_PORT:-14980}"
HUB_PORT="${BASE_PORT}"
D_HTTP=$((BASE_PORT + 1)); D_GRPC=$((BASE_PORT + 2))
CLOSED_PORT=$((BASE_PORT + 3))
PROXY_PORT=$((BASE_PORT + 4))
PROVIDER_PORT=$((BASE_PORT + 5))
METRICS_PORT=$((BASE_PORT + 6))
I_HTTP=$((BASE_PORT + 7)); I_GRPC=$((BASE_PORT + 8))
HUB_URL="http://127.0.0.1:${HUB_PORT}"
DAEMON_URL="http://127.0.0.1:${D_HTTP}"
LAB="hcd-lab"
WEEK="hcd-week"
WEEK_NAME="week daemon"
SVC="hcd-shop"
K="${HCD_K:-8}"
SLOW_MS=250
ORG="Lab Org"
DOMAIN="card-lab.example"
USER_ID="alice.martin@acme.com"
LAB_KEY="$(python3 -c 'print("l" * 40)')"
WEEK_KEY="$(python3 -c 'print("w" * 40)')"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
CHECKS=0
ok()   { CHECKS=$((CHECKS + 1)); color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }
skip() { color_yellow "    skip: $*, scenario skipped"; trap - EXIT; rm -rf "${TMP_DIR}"; exit 0; }

PIDS=()
HUB_PID=""
DAEMON_PID=""
IDLE_PID=""
cleanup() {
  [ -z "${IDLE_PID}" ] || kill "${IDLE_PID}" 2>/dev/null || true
  [ -z "${HUB_PID}" ] || kill "${HUB_PID}" 2>/dev/null || true
  [ -z "${DAEMON_PID}" ] || kill "${DAEMON_PID}" 2>/dev/null || true
  for pid in "${PIDS[@]}"; do kill "${pid}" 2>/dev/null || true; done
  if [ "${KEEP_TMP:-no}" = "yes" ]; then echo "kept ${TMP_DIR}"; else rm -rf "${TMP_DIR}"; fi
  return 0
}
trap cleanup EXIT

wait_http() {  # $1 = url, $2 = what
  for _ in $(seq 1 60); do
    curl -fsS "$1" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  die "$2 not ready on $1"
}

# req NAME METHOD PATH [curl args...]: body in NAME.body, headers in NAME.hdr, prints the code.
req() {
  local name="$1" method="$2" path="$3"; shift 3
  curl -sS -o "${TMP_DIR}/${name}.body" -D "${TMP_DIR}/${name}.hdr" -w '%{http_code}' --max-time 60 \
    -X "${method}" "$@" "${HUB_URL}${path}"
}
hdr() {  # $1 = name, $2 = header (any case); prints its value
  awk -v h="$2" 'tolower($0) ~ "^" tolower(h) ":" { sub(/^[^:]*:[ ]*/, ""); sub(/\r$/, ""); print; exit }' \
    "${TMP_DIR}/$1.hdr"
}
expect_code() {  # $1 = what, $2 = got, $3 = want, $4 = name
  [ "$2" = "$3" ] || die "$1: HTTP $2, want $3 ($(head -c 400 "${TMP_DIR}/$4.body" 2>/dev/null))"
}
# py NAME EXPR...: python over $TMP_DIR with body(name), j(name), q(sql) on the Hub's database.
py() {
  python3 - "${TMP_DIR}" "$@" <<'PY'
import json, re, sqlite3, sys
d = sys.argv[1]
body = lambda n: open(f"{d}/{n}.body", encoding="utf-8").read()
j = lambda n: json.loads(body(n))
def q(sql, *args):
    con = sqlite3.connect(f"file:{d}/hub.db?mode=ro", uri=True, timeout=10)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()
def find(o, key):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == key:
                yield v
            yield from find(v, key)
    elif isinstance(o, list):
        for v in o:
            yield from find(v, key)
exec(sys.argv[2])
PY
}
detail() { py 'print(j(sys.argv[3]).get("detail"))' "$1"; }
# The identity the proxy header carries in phases 1 and 2, on a same-origin JSON write.
AS_USER=(-H "X-Forwarded-User: ${USER_ID}" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json')

step "Prerequisites"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || skip "no daemon binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release in ${PERF_SENTINEL_REPO_PATH})"
[ -f "${HUB_DLL}" ] \
  || skip "no Hub build at ${HUB_DLL} (dotnet build PerfSentinelHub.sln -c Release, or set PERF_SENTINEL_HUB_DLL)"
command -v dotnet >/dev/null || skip "dotnet not on PATH, the Hub runs as a local process"
python3 -c 'import opentelemetry.proto' 2>/dev/null \
  || skip "the OTLP payload needs opentelemetry-proto (pip install opentelemetry-proto)"
for port in "${HUB_PORT}" "${D_HTTP}" "${D_GRPC}" "${CLOSED_PORT}" "${PROXY_PORT}" "${PROVIDER_PORT}" "${METRICS_PORT}" "${I_HTTP}" "${I_GRPC}"; do
  python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1)" "${port}" 2>/dev/null \
    && die "port ${port} already answers, stop that process or set HCD_BASE_PORT"
done
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
"${PERF_SENTINEL_LOCAL_BIN}" card --help >/dev/null 2>&1 \
  || die "${PERF_SENTINEL_LOCAL_BIN} ${BIN_VERSION} has no card subcommand (0.39.0 and later)"
ok "daemon and engine: ${PERF_SENTINEL_LOCAL_BIN} ${BIN_VERSION}"
# Today is a UTC day the run must not leave: the watch, the passes and the key dates all use it.
TO_MIDNIGHT="$(python3 -c 'import time; print(86400 - int(time.time()) % 86400)')"
if [ "${TO_MIDNIGHT}" -lt 600 ]; then
  color_yellow "    ${TO_MIDNIGHT} s to UTC midnight: waiting it out so the run stays within one day"
  sleep $((TO_MIDNIGHT + 5))
fi
# The last closed ISO week (W), the one before (P), the done day (Thursday of W) and an old day.
read -r TODAY TODAY_ISO W_FROM W_TO W_FROM_ISO W_TO_ISO P_FROM P_TO P_FROM_ISO P_TO_ISO DONE_DAY OLD_DAY <<< "$(python3 -c '
import datetime, time
iso = lambda d: (datetime.date(1970, 1, 1) + datetime.timedelta(days=d)).isoformat()
t = int(time.time()) // 86400
monday = t - datetime.date.fromordinal(datetime.date(1970, 1, 1).toordinal() + t).weekday()
w, p = monday - 7, monday - 14
print(t, iso(t), w, w + 6, iso(w), iso(w + 6), p, p + 6, iso(p), iso(p + 6), w + 3, t - 300)')"
DONE_MS=$((DONE_DAY * 86400000 + 36000000))
ok "today ${TODAY_ISO}; card week ${W_FROM_ISO}..${W_TO_ISO}, week before ${P_FROM_ISO}..${P_TO_ISO}"

# --- the daemon, behind a recording proxy -----------------------------------------
printf '%s' "${LAB_KEY}" > "${TMP_DIR}/hub.key"
chmod 600 "${TMP_DIR}/hub.key"
cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${D_HTTP}
listen_port_grpc = ${D_GRPC}
api_enabled = true
trace_ttl_ms = 1000
findings_stdout = false

# Never the operator's own ack store.
[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
slow_query_threshold_ms = ${SLOW_MS}

[daemon.hub_export]
enabled = true
endpoint = "http://127.0.0.1:${PROXY_PORT}/api/import/findings"
source_id = "${LAB}"
api_key_file = "${TMP_DIR}/hub.key"
flush_interval_secs = 1
EOF

# An idle daemon at hcd-week's address: the Hub's poll reaches it, so hcd-week is a
# reachable source, the only kind whose sealed days confirm a fix. It sees no
# traffic and pushes nothing.
cat > "${TMP_DIR}/idle.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${I_HTTP}
listen_port_grpc = ${I_GRPC}
api_enabled = true
findings_stdout = false

[daemon.ack]
enabled = false
EOF
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/idle.toml" >> "${TMP_DIR}/idle.log" 2>&1 &
IDLE_PID=$!
disown "${IDLE_PID}" 2>/dev/null || true
wait_http "http://127.0.0.1:${I_HTTP}/api/status" "the idle daemon"

# Forwards everything to the Hub; each detection push appends
# {status, request, answer} to detections.jsonl. A Hub that is down answers 502.
cat > "${TMP_DIR}/proxy.py" <<'PROXY'
import http.client, json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port, hub_port, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
class H(BaseHTTPRequestHandler):
    def relay(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
        try:
            c = http.client.HTTPConnection("127.0.0.1", hub_port, timeout=30)
            c.request(self.command, self.path, body=raw, headers=headers)
            r = c.getresponse()
            status, answer, ctype = r.status, r.read(), r.getheader("Content-Type", "application/json")
        except OSError:
            status, answer, ctype = 502, b"", "text/plain"
        if self.path.startswith("/api/import/detections"):
            with open(out, "a") as f:
                f.write(json.dumps({"status": status, "request": raw.decode("utf-8", "replace"),
                                    "answer": answer.decode("utf-8", "replace")}) + "\n")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)
    do_POST = do_GET = do_PUT = relay
    def log_message(self, *args):
        pass
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PROXY
python3 "${TMP_DIR}/proxy.py" "${PROXY_PORT}" "${HUB_PORT}" "${TMP_DIR}/detections.jsonl" &
PIDS+=($!); disown "$!" 2>/dev/null || true

start_daemon() {
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" >> "${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  disown "${DAEMON_PID}" 2>/dev/null || true
  wait_http "${DAEMON_URL}/api/status" "the daemon"
}
stop_daemon() {
  kill -TERM "${DAEMON_PID}" 2>/dev/null || true
  for _ in $(seq 1 60); do
    kill -0 "${DAEMON_PID}" 2>/dev/null || { DAEMON_PID=""; return 0; }
    sleep 0.25
  done
  die "the daemon still alive 15 s after SIGTERM"
}
ledger_id() {
  curl -fsS "${DAEMON_URL}/api/status" | python3 -c "import json,sys; print(json.load(sys.stdin)['detection_ledger']['ledger_id'])"
}
post_otlp() {  # $1 = payload file
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"$1")"
  [ "${code}" = "200" ] || die "OTLP POST of $(basename "$1") answered ${code}"
}

# --- the Hub -------------------------------------------------------------------
CARDS_ON=(Hub__Cards__Organisation="${ORG}" Hub__Cards__MaxConcurrentRenders=1)
start_hub() {
  (
    cd "$(dirname "${HUB_DLL}")"
    export ASPNETCORE_URLS="${HUB_URL}"
    export Hub__DatabasePath="${TMP_DIR}/hub.db"
    export Hub__Analysis__ReportDirectory="${TMP_DIR}/reports"
    export Hub__Analysis__EngineBinaryPath="${PERF_SENTINEL_LOCAL_BIN}"
    export Hub__PollInterval="00:00:02"
    export Hub__HttpTimeout="00:00:02"
    export Hub__UpdateCheck__Enabled="false"
    # hcd-lab's address is a closed port: what the Hub holds of it comes from the push.
    export Hub__Sources__0__Id="${LAB}" Hub__Sources__0__Name="lab daemon" Hub__Sources__0__Environment="lab"
    export Hub__Sources__0__BaseUrl="http://127.0.0.1:${CLOSED_PORT}" Hub__Sources__0__ImportApiKey="${LAB_KEY}"
    export Hub__Sources__1__Id="${WEEK}" Hub__Sources__1__Name="${WEEK_NAME}" Hub__Sources__1__Environment="lab"
    export Hub__Sources__1__BaseUrl="http://127.0.0.1:${I_HTTP}" Hub__Sources__1__ImportApiKey="${WEEK_KEY}"
    for kv in "$@"; do export "${kv?}"; done
    exec dotnet "$(basename "${HUB_DLL}")"
  ) >> "${TMP_DIR}/hub.log" 2>&1 &
  HUB_PID=$!
  disown "${HUB_PID}" 2>/dev/null || true
  wait_http "${HUB_URL}/health/ready" "the Hub"
  # A fix only confirms on the sealed days of a reachable source: wait for a good poll of hcd-week.
  for _ in $(seq 1 40); do
    [ "$(py 'print(q("SELECT unreachable_since_ms IS NULL FROM source_state WHERE source_id = ?", sys.argv[3]))' "${WEEK}" 2>/dev/null)" = "[(1,)]" ] && return 0
    sleep 0.5
  done
  die "the Hub never polled ${WEEK} at the idle daemon"
}
stop_hub() {
  kill -TERM "${HUB_PID}" 2>/dev/null || true
  for _ in $(seq 1 60); do
    kill -0 "${HUB_PID}" 2>/dev/null || { HUB_PID=""; return 0; }
    sleep 0.25
  done
  die "the Hub still alive 15 s after SIGTERM"
}
mkdir -p "${TMP_DIR}/reports" "${TMP_DIR}/cards"

# --- payloads --------------------------------------------------------------------
cat > "${TMP_DIR}/build_payload.py" <<'PY'
import sys, time
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

out, kind, n, base, svc_name, slow_ms = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], int(sys.argv[6])
now = time.time_ns()
MS = 1_000_000

def kv(k, v):
    return common.KeyValue(key=k, value=common.AnyValue(string_value=v))

def one_trace(tid, route, table, durations_ms):
    trace_id = tid.to_bytes(16, "big")
    root = (1).to_bytes(8, "big")
    total = sum(durations_ms) + len(durations_ms) + 5
    spans = [trace.Span(trace_id=trace_id, span_id=root, name="GET " + route,
                        kind=trace.Span.SPAN_KIND_SERVER,
                        start_time_unix_nano=now, end_time_unix_nano=now + total * MS,
                        attributes=[kv("http.route", route)])]
    start = now + MS
    for i, ms in enumerate(durations_ms):
        spans.append(trace.Span(
            trace_id=trace_id, span_id=(i + 2).to_bytes(8, "big"), parent_span_id=root,
            name="SELECT", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=start, end_time_unix_nano=start + ms * MS,
            attributes=[kv("db.system", "postgresql"),
                        kv("db.statement", "SELECT * FROM %s WHERE id = %d" % (table, i + 1))]))
        start += (ms + 1) * MS
    return spans

if kind == "n1":        # six quick SELECTs by id: one n_plus_one_sql on /api/orders
    route, table, shape = "/api/orders", "orders", [1] * 6
elif kind == "slow":    # three runs over the threshold: one slow_sql on /api/report
    route, table, shape = "/api/report", "reports", [slow_ms + 150] * 3
elif kind == "below":   # the same template under and exactly at the threshold
    route, table, shape = "/api/report", "reports", [slow_ms - 150, slow_ms]
else:                   # an N+1 elsewhere, which moves the day so the daemon pushes
    route, table, shape = "/api/anchor", "anchors", [1] * 6
spans = [s for t in range(n) for s in one_trace(base + t, route, table, shape)]
rs = trace.ResourceSpans(resource=resource.Resource(attributes=[kv("service.name", svc_name)]),
                         scope_spans=[trace.ScopeSpans(spans=spans)])
open(out, "wb").write(svc.ExportTraceServiceRequest(resource_spans=[rs]).SerializeToString())
PY
build() { python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/$1.pb" "$2" "$3" "$4" "$5" "${SLOW_MS}"; }
build n1 n1 "${K}" 1000 "${SVC}"
build slow slow 1 2000 "${SVC}"
build below below 4 3000 "${SVC}"
build anchor1 anchor 1 4000 hcd-anchor
build anchor2 anchor 1 4100 hcd-anchor

# ================================================================== phase 0
step "H0 phase 0: cards off"
start_daemon
start_hub
HUB_VERSION="$(curl -fsS "${HUB_URL}/api/status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version", "?"))')"
CODE="$(req h0-status GET /api/status -H "X-Forwarded-User: ${USER_ID}")"
expect_code "H0 status" "${CODE}" 200 h0-status
[ "$(py 'print("cards" in j("h0-status"))')" = "False" ] || die "H0 /api/status carries cards with cards off: $(cat "${TMP_DIR}/h0-status.body")"
while read -r method path; do
  CODE="$(req h0-route "${method}" "${path}" "${AS_USER[@]}" --data '{}')"
  expect_code "H0 ${method} ${path} with cards off" "${CODE}" 404 h0-route
done <<'ROUTES'
GET /api/cards/options?period=week
GET /api/cards/keys
POST /api/cards/render
POST /api/cards/attachment
POST /api/cards/keys/rotate
POST /api/cards/keys/revoke
ROUTES
ok "Hub ${HUB_VERSION}: six card routes 404, /api/status has no cards"
stop_hub

# ================================================================== phase 1
step "Phase 1: cards on (${ORG}, ${DOMAIN}, one render at a time), X-Forwarded-User trusted"
PHASE12=(Hub__AckRelay__TrustIdentityHeader=true "${CARDS_ON[@]}" Hub__Cards__Domain="${DOMAIN}")
start_hub "${PHASE12[@]}"
CODE="$(req h1-status GET /api/status -H "X-Forwarded-User: ${USER_ID}")"
expect_code "H1 status" "${CODE}" 200 h1-status
H1_STATUS="$(py 's = j("h1-status"); print(s.get("cards"), s.get("engine_version"))')"
[ "${H1_STATUS}" = "True ${BIN_VERSION}" ] || die "H1 /api/status reads cards/engine_version '${H1_STATUS}', want 'True ${BIN_VERSION}'"
ok "/api/status: cards true, engine ${BIN_VERSION}"

step "H1 the daemon's N+1 and slow SELECT reach the Hub"
LEDGER_1="$(ledger_id)"
post_otlp "${TMP_DIR}/n1.pb"
post_otlp "${TMP_DIR}/slow.pb"
DAEMON=""
for _ in $(seq 1 40); do
  DAEMON="$(curl -fsS "${DAEMON_URL}/api/detections?limit=5000" | python3 -c '
import json, sys
p, k, svc = json.load(sys.stdin), int(sys.argv[1]), sys.argv[2]
n = [r for r in p["counts"] if r["signature"].startswith("n_plus_one_sql:" + svc + ":")]
s = [r for r in p["counts"] if r["signature"].startswith("slow_sql:" + svc + ":")]
if len(n) == 1 and len(s) == 1 and n[0]["detections"] == k and s[0]["detections"] >= 1:
    print(n[0]["signature"], s[0]["signature"], s[0]["detections"])
' "${K}" "${SVC}" 2>/dev/null || true)"
  [ -n "${DAEMON}" ] && break
  sleep 0.5
done
[ -n "${DAEMON}" ] || die "the daemon never counted ${K} N+1 and one slow_sql for ${SVC}"
read -r SIG_N SIG_S S_DETECTIONS <<< "${DAEMON}"
for sig in "${SIG_N}" "${SIG_S}"; do
  for _ in $(seq 1 40); do
    [ "$(curl -fsS "${HUB_URL}/api/findings?signature=${sig}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "1" ] && break
    sleep 0.5
  done
  [ "$(curl -fsS "${HUB_URL}/api/findings?signature=${sig}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "1" ] \
    || die "the Hub never held ${sig}"
done
CODE="$(req h1-n GET "/api/findings?signature=${SIG_N}")"
CITED="$(py 'v = {x for x in find(j("h1-n"), "occurrences") if isinstance(x, int)}; print(v.pop() if len(v) == 1 else "ambiguous:%s" % v)')"
case "${CITED}" in ''|*[!0-9]*) die "H1 the N+1 finding has no single occurrences figure: ${CITED}" ;; esac
ok "${SIG_N} (occurrences ${CITED}) and ${SIG_S} (${S_DETECTIONS} detection) held by the Hub"

step "Import the two weeks ${WEEK} pushed, and one day 300 days old"
python3 - "${SIG_N}" "${P_FROM}" "${W_TO}" "${DONE_DAY}" "${OLD_DAY}" > "${TMP_DIR}/week.json" <<'PY'
import json, sys
sig, first, last, done, old = sys.argv[1], *map(int, sys.argv[2:])
DAY = 86_400_000
def day(d):
    return {"day": d, "sealed": True, "gap": False, "overflow_detections": 0, "overflow_extra_io_ops": 0,
            "shed_traces": 0, "ingest_rejected": 0, "sampling_rate": 1.0,
            "avoidable_gco2": 2.3e-06 * 25 if d < done else 0.0,
            "avoidable_gco2_low": 1.15e-06 * 25 if d < done else 0.0,
            "avoidable_io_ops": 25 if d < done else 0, "total_io_ops": 600}
pages = [
    {"ledger_id": "6c0ffee0-0000-4000-8000-00000000c4d1", "started_ms": first * DAY - 3_600_000,
     "current_day": last, "oldest_day": first, "sealed_through": last, "next_after": None,
     # The planted N+1, six a day until the day before the fix, then clean sealed days.
     "counts": [{"day": d, "signature": sig, "detections": 6, "extra_io_ops": 25} for d in range(first, done)],
     "days": [day(d) for d in range(first, last + 1)]},
    {"ledger_id": "6c0ffee0-0000-4000-8000-00000000c4d0", "started_ms": old * DAY + 3_600_000,
     "current_day": old, "oldest_day": old, "sealed_through": old, "next_after": None,
     "counts": [], "days": [day(old)]},
]
print(json.dumps(pages))
PY
for i in 0 1; do
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[int(sys.argv[2])]))' "${TMP_DIR}/week.json" "${i}" > "${TMP_DIR}/week${i}.json"
  CODE="$(req "week${i}" POST "/api/import/detections?source_id=${WEEK}" -H "X-API-Key: ${WEEK_KEY}" \
    -H 'Content-Type: application/json' --data-binary @"${TMP_DIR}/week${i}.json")"
  expect_code "the ${WEEK} page ${i} import" "${CODE}" 200 "week${i}"
done
WANT_BEFORE=$((7 * 25))
ok "${WEEK}: ${P_FROM_ISO}..${W_TO_ISO} sealed, the N+1 counted until the day before ${DONE_DAY}, plus day ${OLD_DAY}"

step "H1 a done action freezes its finding (schema V20)"
for sig in "${SIG_N}" "${SIG_S}"; do
  CODE="$(req h1-act POST /api/actions "${AS_USER[@]}" --data "{\"signature\":\"${sig}\",\"status\":\"done\"}")"
  expect_code "H1 POST /api/actions done for ${sig}" "${CODE}" 201 h1-act
done
H1_FROZEN="$(py 'r = q("SELECT signature, status, frozen_finding_json FROM finding_actions ORDER BY signature")
print(" ".join("%s:%s:%s" % (s.split(":")[0], st, f is not None and s in f) for s, st, f in r))')"
[ "${H1_FROZEN}" = "n_plus_one_sql:done:True slow_sql:done:True" ] || die "H1 finding_actions reads '${H1_FROZEN}'"
ok "both actions done, each with frozen_finding_json holding its signature"

# ------------------------------------------------------------- H2 C1
step "H2 the watch list reaches a restarted daemon in its push answer"
stop_daemon
start_daemon
LEDGER_2="$(ledger_id)"
[ "${LEDGER_2}" != "${LEDGER_1}" ] || die "H2 the restarted daemon kept ledger ${LEDGER_1}"
post_otlp "${TMP_DIR}/anchor1.pb"
# answers LEDGER [field]: the proxied push answers of a ledger, as JSON.
answers() {
  python3 - "${TMP_DIR}/detections.jsonl" "$1" <<'PY'
import json, sys
out = []
for line in open(sys.argv[1]).read().splitlines():
    r = json.loads(line)
    try:
        req, ans = json.loads(r["request"]), json.loads(r["answer"]) if r["answer"] else None
    except ValueError:
        continue
    if req.get("ledger_id") == sys.argv[2]:
        out.append({"status": r["status"], "answer": ans, "rows": req.get("counts", [])})
print(json.dumps(out))
PY
}
WATCH=""
for _ in $(seq 1 90); do
  WATCH="$(answers "${LEDGER_2}" | python3 -c '
import json, sys
a = [x for x in json.load(sys.stdin) if x["status"] == 200 and x["answer"] and "watch" in x["answer"]]
if a: print(json.dumps(a[0]["answer"]["watch"]))')"
  [ -n "${WATCH}" ] && break
  sleep 1
done
[ -n "${WATCH}" ] || die "H2 no accepted detection push of ledger ${LEDGER_2} within 90 s"
[ "${WATCH}" = "[\"${SIG_S}\"]" ] || die "H2 the push answer watches ${WATCH}, want [\"${SIG_S}\"] (the done slow_sql, not the N+1)"
CODE="$(req h2-week POST "/api/import/detections?source_id=${WEEK}" -H "X-API-Key: ${WEEK_KEY}" \
  -H 'Content-Type: application/json' --data-binary @"${TMP_DIR}/week0.json")"
expect_code "H2 ${WEEK} re-import" "${CODE}" 200 h2-week
[ "$(py 'print(json.dumps(j("h2-week").get("watch")))')" = "[]" ] \
  || die "H2 ${WEEK}, which never detected the slow_sql, is told to watch $(py 'print(j("h2-week").get("watch"))')"
ok "ledger ${LEDGER_2}'s first push answer: watch [${SIG_S}]; ${WEEK}'s answer: watch []"

step "H2 the daemon counts the passes under ${SLOW_MS} ms and pushes them"
post_otlp "${TMP_DIR}/below.pb"
post_otlp "${TMP_DIR}/anchor2.pb"
ROW=""
for _ in $(seq 1 40); do
  ROW="$(curl -fsS "${DAEMON_URL}/api/detections?limit=5000" | python3 -c '
import json, sys
p, sig = json.load(sys.stdin), sys.argv[1]
r = [r for r in p["counts"] if r["signature"] == sig and r["day"] == p["current_day"]]
if r and r[0].get("below_threshold_passes") == 8: print(r[0]["detections"], r[0]["below_threshold_passes"])
' "${SIG_S}" 2>/dev/null || true)"
  [ -n "${ROW}" ] && break
  sleep 0.5
done
[ "${ROW}" = "0 8" ] || die "H2 the daemon's row for ${SIG_S} reads '${ROW}', want detections 0, below_threshold_passes 8"
PUSHED=""
for _ in $(seq 1 100); do
  PUSHED="$(answers "${LEDGER_2}" | python3 -c '
import json, sys
sig = sys.argv[1]
for x in json.load(sys.stdin):
    for r in x["rows"]:
        if r["signature"] == sig and r.get("below_threshold_passes") == 8 and x["status"] == 200:
            print(r["detections"], r["below_threshold_passes"]); sys.exit()' "${SIG_S}")"
  [ -n "${PUSHED}" ] && break
  sleep 1
done
[ "${PUSHED}" = "0 8" ] || die "H2 no accepted push of ledger ${LEDGER_2} carried ${SIG_S} with 8 passes within 100 s"
H2_DB="$(py 'print(q("SELECT detections, below_threshold_passes FROM detection_counts WHERE signature = ? AND source_id = ? AND ledger_id = ?", sys.argv[3], sys.argv[4], sys.argv[5]))' \
  "${SIG_S}" "${LAB}" "${LEDGER_2}")"
[ "${H2_DB}" = "[(0, 8)]" ] || die "H2 the Hub stores ${H2_DB} for ${SIG_S} in ledger ${LEDGER_2}, want [(0, 8)]"
CODE="$(req h2-read GET "/api/findings?signature=${SIG_S}&from=$((TODAY * 86400000))&to=$(python3 -c 'import time; print(int(time.time()*1000))')")"
expect_code "H2 windowed read" "${CODE}" 200 h2-read
H2_READ="$(py 'f = j("h2-read")[0]; print(f["detections"], [s.get("detections") for s in f["sources"] if s["id"] == sys.argv[3]])' "${LAB}")"
[ "${H2_READ}" = "${S_DETECTIONS} [${S_DETECTIONS}]" ] \
  || die "H2 the windowed read counts '${H2_READ}', want ${S_DETECTIONS} (the passes are no detection)"
ok "daemon row detections 0 / passes 8, pushed (200), stored (0, 8), the windowed read still ${S_DETECTIONS}"

# ------------------------------------------------------------- backdate the fix
step "Move the N+1 action's done date into ${W_FROM_ISO}..${W_TO_ISO} (Hub stopped, one UPDATE)"
stop_hub
python3 - "${TMP_DIR}/hub.db" "${SIG_N}" "${DONE_MS}" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
with con:
    a = con.execute("UPDATE finding_actions SET created_at_ms = ?, updated_at_ms = ?, done_at_ms = ? WHERE signature = ?",
                    (int(sys.argv[3]),) * 3 + (sys.argv[2],)).rowcount
    con.execute("UPDATE finding_action_events SET at_ms = ? WHERE signature = ?", (int(sys.argv[3]), sys.argv[2]))
assert a == 1, a
PY
ok "done_at_ms ${DONE_MS} (day ${DONE_DAY}, 10:00 UTC)"

# ================================================================== phase 2
step "Phase 2: the same Hub, restarted on the edited database"
start_hub "${PHASE12[@]}"

step "H7 a day 300 days old outlives the boot purge (DetectionRetention 1,100 days)"
sleep 3
[ "$(py 'print(q("SELECT count(*) FROM detection_days WHERE source_id = ? AND day = ?", sys.argv[3], int(sys.argv[4]))[0][0])' "${WEEK}" "${OLD_DAY}")" = "1" ] \
  || die "H7 the default boot purge dropped day ${OLD_DAY}, older than Hub:Retention (180 days) but within 1,100"
ok "day ${OLD_DAY} kept after the boot purge"

step "H3 the closed week's options and recap"
CODE="$(req h3-opt GET "/api/cards/options?period=week&at=${W_FROM_ISO}" -H "X-Forwarded-User: ${USER_ID}")"
expect_code "H3 options" "${CODE}" 200 h3-opt
H3="$(py 'o = j("h3-opt"); f = o["fixes"]
print(o["refusal"], o["sources"], o["restart_days"], o["previous_whole"], o["confirmed_fixes_count"], o["period"]["from"], o["period"]["to"],
      [(x["signature"] == sys.argv[3], x["before_fix_ops"], x["done_at_ms"]) for x in f], o["default_signature"] == sys.argv[3], o["org"])' "${SIG_N}")"
WANT_H3="None ['${WEEK_NAME}'] 0 True 1 ${W_FROM_ISO} ${W_TO_ISO} [(True, ${WANT_BEFORE}, ${DONE_MS})] True {'name': '${ORG}', 'domain': '${DOMAIN}'}"
[ "${H3}" = "${WANT_H3}" ] || die "H3 the options read
      ${H3}
 want ${WANT_H3}"
ok "options: no refusal, signed scope [${WEEK_NAME}] (the late daemon left out), 1 confirmed fix, ${WANT_BEFORE} I/O before"
CODE="$(req h3-recap GET "/api/recap?period=week&at=${W_FROM_ISO}")"
expect_code "H3 week recap" "${CODE}" 200 h3-recap
LATE="$(py 'print(j("h3-recap").get("late_sources"))')"
[ "${LATE}" = "['lab daemon']" ] || die "H3 the week recap's late_sources is ${LATE}, want ['lab daemon'] (${LAB}'s name)"
ok "the week recap names late_sources ['lab daemon'], ${LAB}"

step "H4 a story card in four formats, each verified offline"
CODE="$(req h4-keys0 GET /api/cards/keys -H "X-Forwarded-User: ${USER_ID}")"
expect_code "H4 keys before any card" "${CODE}" 200 h4-keys0
[ "$(py 'print(j("h4-keys0")["keys"])')" = "[]" ] || die "H4 reading the keys made one: $(cat "${TMP_DIR}/h4-keys0.body")"
CARD_BODY() { printf '{"angle":"story","period":"week","at":"%s","signature":"%s","title":"Orders, lighter","team":"Shop team","label":"Showing an order","format":"%s"}' "${W_FROM_ISO}" "${SIG_N}" "$1"; }
# bash 3.2 cannot parse a case inside $(...), so the lookup is a function.
mime() {
  case "$1" in png) echo image/png ;; svg) echo image/svg+xml ;; jxl) echo image/jxl ;; pdf) echo application/pdf ;; esac
}
verify_card() {  # $1 = file, then verify-card options; prints "<exit> <json line>"
  local file="$1" out rc=0; shift
  out="$("${PERF_SENTINEL_LOCAL_BIN}" verify-card "${file}" "$@" 2>/dev/null)" || rc=$?
  printf '%s %s' "${rc}" "${out}"
}
for fmt in png svg jxl pdf; do
  CODE="$(curl -sS -o "${TMP_DIR}/cards/card1.${fmt}" -D "${TMP_DIR}/h4-${fmt}.hdr" -w '%{http_code}' --max-time 60 \
    -X POST "${AS_USER[@]}" --data "$(CARD_BODY "${fmt}")" "${HUB_URL}/api/cards/render")"
  cp "${TMP_DIR}/cards/card1.${fmt}" "${TMP_DIR}/h4-${fmt}.body"
  expect_code "H4 render ${fmt}" "${CODE}" 200 "h4-${fmt}"
  want_type="$(mime "${fmt}")"
  [ "$(hdr "h4-${fmt}" Content-Type)" = "${want_type}" ] || die "H4 ${fmt} Content-Type $(hdr "h4-${fmt}" Content-Type)"
  hdr "h4-${fmt}" Content-Disposition | grep -q "filename=perf-sentinel-card-week-${W_FROM_ISO}.${fmt}" \
    || die "H4 ${fmt} Content-Disposition '$(hdr "h4-${fmt}" Content-Disposition)'"
  [ "$(hdr "h4-${fmt}" Cache-Control)" = "no-store" ] && [ "$(hdr "h4-${fmt}" X-Content-Type-Options)" = "nosniff" ] \
    || die "H4 ${fmt} lacks no-store or nosniff"
  if [ "${fmt}" = "svg" ]; then
    [ "$(hdr h4-svg Content-Security-Policy)" = "default-src 'none'; sandbox" ] || die "H4 the SVG CSP is '$(hdr h4-svg Content-Security-Policy)'"
  fi
  V="$(verify_card "${TMP_DIR}/cards/card1.${fmt}")"
  python3 - "${V}" "${DOMAIN}" "${W_FROM_ISO}" "${W_TO_ISO}" "${P_FROM_ISO}" "${P_TO_ISO}" "${CITED}" "${WANT_BEFORE}" <<'PY' || die "H4 verify-card ${fmt}: ${V}"
import json, sys
rc, line = sys.argv[1].split(" ", 1)
v = json.loads(line)
dom, wf, wt, pf, pt, cited, before = sys.argv[2:]
f = v["figures"]
assert rc == "0", rc
assert (v["integrity"], v["content"], v["level"], v["domain"]) == ("ok", "intact", 1, dom), v
assert f["angle"] == "story" and (f["period"]["from"], f["period"]["to"]) == (wf, wt), f
assert (f["before_fix_period"]["from"], f["before_fix_period"]["to"]) == (pf, pt), f
assert (f["cited_ops"], f["before_fix_ops"]) == (int(cited), int(before)), f
PY
done
ok "png, svg, jxl, pdf: 200 with type, filename, no-store, nosniff (SVG CSP sandboxed); verify-card exit 0, intact, level 1, ${CITED} cited, ${WANT_BEFORE} before"

step "H5 the signing key, its rotation and its revocation"
CODE="$(req h5-keys1 GET /api/cards/keys -H "X-Forwarded-User: ${USER_ID}")"
expect_code "H5 keys" "${CODE}" 200 h5-keys1
FP1="$(py 'k = j("h5-keys1"); assert k["record_name"] == "_perf-sentinel." + sys.argv[3], k
assert len(k["keys"]) == 1, k
x = k["keys"][0]
assert (x["current"], x["from"], x["to"], x["revoked"]) == (True, sys.argv[4], None, None), x
assert x["dns"] == "v=ps1; k=%s; from=%s" % (x["fingerprint"], sys.argv[4]), x
open(sys.argv[1] + "/keys1.json", "w").write(k["well_known"])
print(x["fingerprint"])' "${DOMAIN}" "${TODAY_ISO}")" || die "H5 the first key list: $(cat "${TMP_DIR}/h5-keys1.body")"
V="$(verify_card "${TMP_DIR}/cards/card1.png" --keys "${TMP_DIR}/keys1.json")"
python3 -c 'import json,sys; rc,l=sys.argv[1].split(" ",1); v=json.loads(l); assert rc=="0" and v["level"]==2 and v["key"]=="current", v' "${V}" \
  || die "H5 verify-card --keys keys1 on card 1: ${V}"
ok "one key ${FP1}, current from ${TODAY_ISO}, DNS 'v=ps1; k=${FP1}; from=${TODAY_ISO}'; card 1 level 2 against its well-known"

CODE="$(req h5-rot POST /api/cards/keys/rotate "${AS_USER[@]}" --data '{}')"
expect_code "H5 rotate" "${CODE}" 200 h5-rot
FP2="$(py 'k = j("h5-rot"); ks = {x["fingerprint"]: x for x in k["keys"]}
old, = [x for x in k["keys"] if x["fingerprint"] == sys.argv[3]]
new, = [x for x in k["keys"] if x["fingerprint"] != sys.argv[3]]
assert len(ks) == 2 and (old["current"], old["to"]) == (False, sys.argv[4]) and new["current"] and new["to"] is None, k
assert new["dns"].startswith("v=ps1; k=%s; from=%s" % (new["fingerprint"], sys.argv[4])) and old["dns"] != j("h5-keys1")["keys"][0]["dns"], (old, new)
open(sys.argv[1] + "/keys2.json", "w").write(k["well_known"])
print(new["fingerprint"], "|", old["dns"])' "${FP1}" "${TODAY_ISO}")" || die "H5 the rotation answer: $(cat "${TMP_DIR}/h5-rot.body")"
OLD_DNS="${FP2#*| }"; FP2="${FP2%% |*}"
CODE="$(curl -sS -o "${TMP_DIR}/cards/card2.png" -w '%{http_code}' --max-time 60 -X POST "${AS_USER[@]}" \
  --data "$(CARD_BODY png)" "${HUB_URL}/api/cards/render")"
[ "${CODE}" = "200" ] || die "H5 render after the rotation: HTTP ${CODE}"
V1="$(verify_card "${TMP_DIR}/cards/card1.png" --keys "${TMP_DIR}/keys2.json")"
V2="$(verify_card "${TMP_DIR}/cards/card2.png" --keys "${TMP_DIR}/keys2.json")"
python3 -c 'import json,sys
for a in sys.argv[1:]:
    rc, l = a.split(" ", 1); v = json.loads(l); assert rc == "0" and v["level"] == 2, v' "${V1}" "${V2}" \
  || die "H5 after the rotation, card 1: ${V1}; card 2: ${V2}"
ok "rotated: ${FP1} retired (to ${TODAY_ISO}, DNS '${OLD_DNS}'), ${FP2} current; card 1 and card 2 both level 2"

CODE="$(req h5-rev POST /api/cards/keys/revoke "${AS_USER[@]}" --data "{\"fingerprint\":\"${FP1}\",\"revoked\":\"${TODAY_ISO}\"}")"
expect_code "H5 revoke" "${CODE}" 200 h5-rev
REV_DNS="$(py 'k = j("h5-rev"); old, = [x for x in k["keys"] if x["fingerprint"] == sys.argv[3]]
assert old["revoked"] == sys.argv[4] and "revoked=" in old["dns"], old
open(sys.argv[1] + "/keys3.json", "w").write(k["well_known"])
print(old["dns"])' "${FP1}" "${TODAY_ISO}")" || die "H5 the revocation answer: $(cat "${TMP_DIR}/h5-rev.body")"
V1="$(verify_card "${TMP_DIR}/cards/card1.png" --keys "${TMP_DIR}/keys3.json")"
V2="$(verify_card "${TMP_DIR}/cards/card2.png" --keys "${TMP_DIR}/keys3.json")"
python3 -c 'import json,sys
rc, l = sys.argv[1].split(" ", 1); v = json.loads(l); assert rc == "1" and v["key"] == "revoked" and v["reason"] == "key_revoked", v
rc, l = sys.argv[2].split(" ", 1); v = json.loads(l); assert rc == "0" and v["level"] == 2, v' "${V1}" "${V2}" \
  || die "H5 after the revocation, card 1: ${V1}; card 2: ${V2}"
CODE="$(req h5-unknown POST /api/cards/keys/revoke "${AS_USER[@]}" --data "{\"fingerprint\":\"ps1:AAAAAAAAAAAAAAAAAAAAAA\",\"revoked\":\"${TODAY_ISO}\"}")"
expect_code "H5 revoke an unknown key" "${CODE}" 404 h5-unknown
ok "revoked ${FP1} (DNS '${REV_DNS}'): card 1 exit 1 key_revoked, card 2 still level 2; an unknown fingerprint 404"

step "H6 past Hub:Cards:MaxConcurrentRenders (1), a render is a 503 with Retry-After"
BUSY=""
for round in 1 2 3 4 5; do
  rm -f "${TMP_DIR}"/busy-*.hdr "${TMP_DIR}"/busy-*.body
  for i in 1 2 3 4; do
    curl -sS -o "${TMP_DIR}/busy-${i}.body" -D "${TMP_DIR}/busy-${i}.hdr" -w '%{http_code}\n' --max-time 60 \
      -X POST "${AS_USER[@]}" --data "$(CARD_BODY pdf)" "${HUB_URL}/api/cards/render" > "${TMP_DIR}/busy-${i}.code" &
  done
  wait
  BUSY="$(py '
codes, busy = [], []
for i in range(1, 5):
    c = open(f"{d}/busy-{i}.code").read().strip(); codes.append(c)
    if c == "503":
        h = open(f"{d}/busy-{i}.hdr").read().lower()
        busy.append(("retry-after: 5" in h, j(f"busy-{i}").get("detail")))
if "200" in codes and busy: print(sorted(codes), busy[0][0], busy[0][1])')"
  [ -n "${BUSY}" ] && break
done
[ -n "${BUSY}" ] || die "H6 five rounds of 4 parallel renders never gave both a 200 and a 503"
case "${BUSY}" in *"True Another card is being made. Try again in a few seconds.") ;; *) die "H6 the busy answer reads '${BUSY}'" ;; esac
ok "round ${round}: ${BUSY}"

step "H1 an action leaving done drops its frozen finding"
CODE="$(req h1-patch PATCH /api/actions "${AS_USER[@]}" --data "{\"signature\":\"${SIG_S}\",\"status\":\"in_progress\"}")"
expect_code "H1 PATCH to in_progress" "${CODE}" 200 h1-patch
[ "$(py 'print(q("SELECT frozen_finding_json IS NULL, done_at_ms IS NULL FROM finding_actions WHERE signature = ?", sys.argv[3]))' "${SIG_S}")" = "[(1, 1)]" ] \
  || die "H1 ${SIG_S} keeps its frozen finding or done_at_ms after leaving done"
ok "${SIG_S} in_progress: frozen_finding_json and done_at_ms cleared"
stop_hub

# ================================================================== phase 3
step "Phase 3: access control (alice member, bob reader), no Hub:Cards:Domain, DetectionRetention 200 days"
hash_pw() {
  (cd "$(dirname "${HUB_DLL}")" && printf '%s\n' "$1" | dotnet "$(basename "${HUB_DLL}")" hash-password)
}
ALICE_PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
BOB_PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
ALICE_HASH="$(hash_pw "${ALICE_PW}")"
BOB_HASH="$(hash_pw "${BOB_PW}")"
case "${ALICE_HASH}${BOB_HASH}" in '$pbkdf2-sha256$'*'$pbkdf2-sha256$'*) ;; *) die "hash-password printed '${ALICE_HASH}'" ;; esac
# The provider is never called: local accounts sign in without it, but Hub:Auth must name one.
start_hub "${CARDS_ON[@]}" Hub__DetectionRetention=200.00:00:00 \
  ASPNETCORE_URLS="${HUB_URL};http://127.0.0.1:${METRICS_PORT}" Hub__MetricsPort="${METRICS_PORT}" \
  Hub__Access__Admins__0=lab-admin@lab.example \
  Hub__Auth__Enabled=true \
  Hub__Auth__AuthorizationEndpoint="http://127.0.0.1:${PROVIDER_PORT}/authorize" \
  Hub__Auth__TokenEndpoint="http://127.0.0.1:${PROVIDER_PORT}/token" \
  Hub__Auth__UserInformationEndpoint="http://127.0.0.1:${PROVIDER_PORT}/userinfo" \
  Hub__Auth__ClientId=lab Hub__Auth__ClientSecret=lab \
  Hub__Auth__TrustedProxyNetworks__0=127.0.0.1/32 \
  Hub__Access__Enabled=true \
  Hub__Access__Groups__0__Name=alices Hub__Access__Groups__0__Members__0=local:alice \
  Hub__Access__Groups__1__Name=bobs Hub__Access__Groups__1__Members__0=local:bob \
  Hub__Access__Grants__0__Group=internal:alices Hub__Access__Grants__0__Project="*" Hub__Access__Grants__0__Role=member \
  Hub__Access__Grants__1__Group=internal:bobs Hub__Access__Grants__1__Project="*" Hub__Access__Grants__1__Role=reader \
  Hub__Access__LocalAccounts__0__Name=alice Hub__Access__LocalAccounts__0__PasswordHash="${ALICE_HASH}" \
  Hub__Access__LocalAccounts__1__Name=bob Hub__Access__LocalAccounts__1__PasswordHash="${BOB_HASH}"
sign_in() {  # $1 = name, $2 = password; prints the hub_session cookie pair
  local code
  code="$(req "signin-$1" POST /auth/sign-in/local -H 'Sec-Fetch-Site: same-origin' \
    --data-urlencode "name=$1" --data-urlencode "password=$2" --data-urlencode "return_url=/")"
  [ "${code}" = "302" ] || die "H8 local sign-in of $1: HTTP ${code}"
  awk 'tolower($1) == "set-cookie:" && $2 ~ /^hub_session=/ { sub(/;.*/, "", $2); print $2; exit }' "${TMP_DIR}/signin-$1.hdr"
}
ALICE="$(sign_in alice "${ALICE_PW}")"
BOB="$(sign_in bob "${BOB_PW}")"
[ -n "${ALICE}" ] && [ -n "${BOB}" ] || die "H8 a local sign-in set no hub_session"
ok "alice and bob signed in with local accounts"

step "H7 a shorter Hub:DetectionRetention purges the old day at boot, not last weeks"
H7=""
for _ in $(seq 1 40); do
  H7="$(py 'print(q("SELECT count(*) FROM detection_days WHERE source_id = ? AND day = ?", sys.argv[3], int(sys.argv[4]))[0][0],
               q("SELECT count(*) FROM detection_days WHERE source_id = ? AND day = ?", sys.argv[3], int(sys.argv[5]))[0][0])' \
    "${WEEK}" "${OLD_DAY}" "${P_FROM}")"
  [ "${H7}" = "0 1" ] && break
  sleep 0.5
done
[ "${H7}" = "0 1" ] || die "H7 with DetectionRetention 200 days, day ${OLD_DAY} / day ${P_FROM} rows read '${H7}', want '0 1'"
ok "day ${OLD_DAY} purged, ${P_FROM_ISO} kept"

step "H8 cards.write and access.admin under access control"
WRITE=(-H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json')
CODE="$(req h8-bob-status GET /api/status -H "Cookie: ${BOB}")"
expect_code "H8 bob status" "${CODE}" 200 h8-bob-status
CODE="$(req h8-alice-status GET /api/status -H "Cookie: ${ALICE}")"
expect_code "H8 alice status" "${CODE}" 200 h8-alice-status
H8_STATUS="$(py 'print("cards" in j("h8-bob-status"), j("h8-alice-status").get("cards"))')"
[ "${H8_STATUS}" = "False True" ] || die "H8 /api/status cards for bob/alice reads '${H8_STATUS}', want 'False True'"
CODE="$(req h8-bob-opt GET "/api/cards/options?period=week&at=${W_FROM_ISO}" -H "Cookie: ${BOB}")"
expect_code "H8 bob options" "${CODE}" 403 h8-bob-opt
[ "$(detail h8-bob-opt)" = "You may not create cards." ] || die "H8 bob's options 403 reads '$(detail h8-bob-opt)'"
CODE="$(req h8-bob-render POST /api/cards/render -H "Cookie: ${BOB}" "${WRITE[@]}" --data "$(CARD_BODY png)")"
expect_code "H8 bob render" "${CODE}" 403 h8-bob-render
[ "$(detail h8-bob-render)" = "You may not create cards." ] || die "H8 bob's render 403 reads '$(detail h8-bob-render)'"
ok "bob (reader, no cards.write): no cards in /api/status, options and render 403 'You may not create cards.'"
CODE="$(req h8-alice-opt GET "/api/cards/options?period=week&at=${W_FROM_ISO}" -H "Cookie: ${ALICE}")"
expect_code "H8 alice options" "${CODE}" 200 h8-alice-opt
[ "$(py 'o = j("h8-alice-opt"); print(o["refusal"], [x["signature"] == sys.argv[3] for x in o["fixes"]], o["org"])' "${SIG_N}")" = "None [True] {'name': '${ORG}', 'domain': None}" ] \
  || die "H8 alice's options read $(head -c 400 "${TMP_DIR}/h8-alice-opt.body")"
CODE="$(req h8-alice-keys GET /api/cards/keys -H "Cookie: ${ALICE}")"
expect_code "H8 alice keys" "${CODE}" 403 h8-alice-keys
[ "$(detail h8-alice-keys)" = "You may not manage the card signing key." ] || die "H8 alice's keys 403 reads '$(detail h8-alice-keys)'"
CODE="$(req h8-alice-att POST /api/cards/attachment -H "Cookie: ${ALICE}" "${WRITE[@]}" --data "$(CARD_BODY png)")"
expect_code "H8 alice attachment without a domain" "${CODE}" 409 h8-alice-att
[ "$(detail h8-alice-att)" = "Set Hub:Cards:Domain to check an attachment." ] || die "H8 the attachment 409 reads '$(detail h8-alice-att)'"
ok "alice (member): cards true, options 200 with the fix, keys 403, attachment 409 'Set Hub:Cards:Domain to check an attachment.'"

{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Daemon and engine: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo "- Hub: ${HUB_DLL} (${HUB_VERSION})"
  echo "- Today ${TODAY_ISO}; card week ${W_FROM_ISO}..${W_TO_ISO}; fix done ${DONE_MS} (forged)"
  echo "- N+1 ${SIG_N}: cited ${CITED}, ${WANT_BEFORE} I/O the week before"
  echo "- slow ${SIG_S}: watch ${WATCH}, row (0, 8) in ledger ${LEDGER_2}"
  echo "- keys: ${FP1} rotated then revoked, ${FP2} current"
  echo "- busy: ${BUSY}"
  echo ""
  echo "PASS, ${CHECKS} checks"
} > "${REPORT}"
color_green "PASS, ${CHECKS} checks, report at ${REPORT}"
