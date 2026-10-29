#!/usr/bin/env bash
# hub-recap: the Hub 0.9.0 review recap, end to end, from a 0.38.0 daemon
# scoring carbon to the frozen reports a subscription mails and signs.
#
# A local PerfSentinelHub process (a Release build, no cluster, no Docker)
# knows one source, hrc-lab, which a local daemon pushes to (green scoring on,
# eu-west-3). The daemon receives two N+1 of one service, on /api/orders and on
# /api/invoices. The Hub restarts twice on the same database: phase 1 with the
# proxy identity header trusted, phase 2 with a daily subscription, phase 3
# with access control and two local accounts.
#
#   R1 the day carbon reaches the recap: today's tech recap prices the planted
#      N+1 at the daemon's own grams per avoidable I/O, volume measured.
#   R2 an action without an identity is a 403; with X-Forwarded-User it is a
#      201, and the recap carries it with its owner.
#   R3 an endpoint label and a service label title the rows of the
#      management view, whose JSON holds no technical key.
#   R4 an on-demand report of yesterday: 201, listed, both pages 200,
#      self-contained, with a CSP.
#   R5 the management page names the owner without an e-mail, has no @ outside
#      its stylesheet, and the unlabelled row reads "An unnamed step in".
#   R6 the subscription freezes yesterday and POSTs it to a local receiver,
#      HMAC-SHA256 over "<timestamp>.<body>" under the webhook secret.
#   R7 the same report reaches a local SMTP sink with the management page
#      attached, no @ in its HTML outside the stylesheet.
#   R8 with access control, a report alice generated answers 404 to bob, who
#      holds findings.read but not recaps.read, as an unknown id does.
#
# A daemon started today holds no sealed yesterday, and a subscription only
# freezes a closed period. The scenario therefore pushes, with the source's
# import key, the ledger page a previous daemon instance would have pushed for
# yesterday: the same two signatures, sealed, with carbon. Everything else is
# the daemon's own data.
set -euo pipefail

SCENARIO="hub-recap"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
rm -f "${REPORT}"  # die() prints it, never show a previous run's verdict
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCENARIO}.XXXXXX")"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
PERF_SENTINEL_HUB_REPO_PATH="${PERF_SENTINEL_HUB_REPO_PATH:-${HOME}/RiderProjects/PerfSentinelHub}"
HUB_DLL="${PERF_SENTINEL_HUB_DLL:-${PERF_SENTINEL_HUB_REPO_PATH}/PerfSentinelHub/bin/Release/net10.0/PerfSentinelHub.dll}"
BASE_PORT="${HRC_BASE_PORT:-14970}"
HUB_PORT="${BASE_PORT}"
D_HTTP=$((BASE_PORT + 1)); D_GRPC=$((BASE_PORT + 2))
CLOSED_PORT=$((BASE_PORT + 3))
HOOK_PORT=$((BASE_PORT + 4))
SMTP_PORT=$((BASE_PORT + 5))
PROVIDER_PORT=$((BASE_PORT + 6))
METRICS_PORT=$((BASE_PORT + 7))
HUB_URL="http://127.0.0.1:${HUB_PORT}"
SOURCE="hrc-lab"
SVC="hrc-shop"
K="${HRC_K:-8}"
OWNER="alice.martin@acme.com"
OWNER_NAME="Alice Martin"
ENDPOINT_LABEL="Showing an order"
SERVICE_LABEL="Shop front"
MAIL_TO="team.lead@acme.example"
IMPORT_KEY="$(python3 -c 'print("r" * 40)')"
HOOK_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"

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
cleanup() {
  [ -z "${HUB_PID}" ] || kill "${HUB_PID}" 2>/dev/null || true
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
  curl -sS -o "${TMP_DIR}/${name}.body" -D "${TMP_DIR}/${name}.hdr" -w '%{http_code}' --max-time 20 \
    -X "${method}" "$@" "${HUB_URL}${path}"
}
hdr() {  # $1 = name, $2 = header (any case); prints its value
  awk -v h="$2" 'tolower($0) ~ "^" tolower(h) ":" { sub(/^[^:]*:[ ]*/, ""); sub(/\r$/, ""); print; exit }' \
    "${TMP_DIR}/$1.hdr"
}
expect_code() {  # $1 = what, $2 = got, $3 = want, $4 = name
  [ "$2" = "$3" ] || die "$1: HTTP $2, want $3 ($(head -c 400 "${TMP_DIR}/$4.body" 2>/dev/null))"
}
# py NAME EXPR...: runs python over $TMP_DIR with `body(name)` and `j(name)` helpers.
py() {
  python3 - "${TMP_DIR}" "$@" <<'PY'
import json, re, sys
d = sys.argv[1]
body = lambda n: open(f"{d}/{n}.body", encoding="utf-8").read()
j = lambda n: json.loads(body(n))
def keys(o):
    if isinstance(o, dict):
        for k, v in o.items():
            yield k
            yield from keys(v)
    elif isinstance(o, list):
        for v in o:
            yield from keys(v)
no_style = lambda html: re.sub(r"(?is)<style\b.*?</style>", "", html)
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
exec(sys.argv[2])
PY
}

step "Prerequisites"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || skip "no daemon binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release in ${PERF_SENTINEL_REPO_PATH})"
[ -f "${HUB_DLL}" ] \
  || skip "no Hub build at ${HUB_DLL} (dotnet build PerfSentinelHub.sln -c Release, or set PERF_SENTINEL_HUB_DLL)"
command -v dotnet >/dev/null || skip "dotnet not on PATH, the Hub runs as a local process"
python3 -c 'import opentelemetry.proto' 2>/dev/null \
  || skip "the OTLP payload needs opentelemetry-proto (pip install opentelemetry-proto)"
for port in "${HUB_PORT}" "${D_HTTP}" "${D_GRPC}" "${CLOSED_PORT}" "${HOOK_PORT}" "${SMTP_PORT}" "${PROVIDER_PORT}" "${METRICS_PORT}"; do
  python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1)" "${port}" 2>/dev/null \
    && die "port ${port} already answers, stop that process or set HRC_BASE_PORT"
done
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
ok "daemon: ${PERF_SENTINEL_LOCAL_BIN} ${BIN_VERSION}"
ok "Hub: ${HUB_DLL}"
# Today and yesterday are UTC days: a run across midnight would split the load between two.
TO_MIDNIGHT="$(python3 -c 'import time; print(86400 - int(time.time()) % 86400)')"
if [ "${TO_MIDNIGHT}" -lt 420 ]; then
  color_yellow "    ${TO_MIDNIGHT} s to UTC midnight: waiting it out so the run stays within one day"
  sleep $((TO_MIDNIGHT + 5))
fi
read -r TODAY YESTERDAY YESTERDAY_ISO <<< "$(python3 -c '
import datetime, time
d = int(time.time()) // 86400
print(d, d - 1, (datetime.date(1970, 1, 1) + datetime.timedelta(days=d - 1)).isoformat())')"

# --- daemon ------------------------------------------------------------------
printf '%s' "${IMPORT_KEY}" > "${TMP_DIR}/hub.key"
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

[daemon.hub_export]
enabled = true
endpoint = "${HUB_URL}/api/import/findings"
source_id = "${SOURCE}"
api_key_file = "${TMP_DIR}/hub.key"
flush_interval_secs = 1

[detection]
n_plus_one_min_occurrences = 5

[green]
enabled = true
default_region = "eu-west-3"
EOF

# --- the webhook receiver and the SMTP sink ------------------------------------
mkdir -p "${TMP_DIR}/hook" "${TMP_DIR}/mail"
cat > "${TMP_DIR}/hook.py" <<'HOOK'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port, out = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        n = time.time_ns()
        json.dump({"path": self.path, "headers": dict(self.headers.items())}, open(f"{out}/{n}.json", "w"))
        open(f"{out}/{n}.tmp", "wb").write(raw)
        os.rename(f"{out}/{n}.tmp", f"{out}/{n}.raw")  # the .raw appears whole
        self.send_response(204)
        self.end_headers()
    def log_message(self, *args):
        pass
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
HOOK
cat > "${TMP_DIR}/smtp.py" <<'SMTP'
# A loopback relay that stores what it is handed, as the Hub's own FakeSmtp test helper does.
import os, socketserver, sys, time
port, out = int(sys.argv[1]), sys.argv[2]
class H(socketserver.StreamRequestHandler):
    def say(self, *lines):
        self.wfile.write("".join(l + "\r\n" for l in lines).encode())
        self.wfile.flush()
    def handle(self):
        self.say("220 lab-sink ESMTP")
        rcpt = []
        while True:
            line = self.rfile.readline()
            if not line:
                return
            cmd = line.decode("utf-8", "replace").strip()
            up = cmd.upper()
            if up.startswith("EHLO"):
                self.say("250-lab-sink", "250 8BITMIME")
            elif up.startswith("RCPT TO:"):
                rcpt.append(cmd[8:].strip().strip("<>"))
                self.say("250 OK")
            elif up == "DATA":
                self.say("354 End data with <CR><LF>.<CR><LF>")
                data = []
                while True:
                    l = self.rfile.readline()
                    if not l or l in (b".\r\n", b".\n"):
                        break
                    data.append(l[1:] if l.startswith(b"..") else l)
                n = time.time_ns()
                open(f"{out}/{n}.rcpt", "w").write("\n".join(rcpt))
                open(f"{out}/{n}.tmp", "wb").write(b"".join(data))
                os.rename(f"{out}/{n}.tmp", f"{out}/{n}.eml")
                rcpt = []
                self.say("250 OK queued")
            elif up == "QUIT":
                self.say("221 Bye")
                return
            else:
                self.say("250 OK")
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
S(("127.0.0.1", port), H).serve_forever()
SMTP

# --- the Hub -----------------------------------------------------------------
# start_hub VAR=value...: the common settings, then the phase's own.
start_hub() {
  (
    cd "$(dirname "${HUB_DLL}")"
    export ASPNETCORE_URLS="${HUB_URL}"
    export Hub__DatabasePath="${TMP_DIR}/hub.db"
    export Hub__Analysis__ReportDirectory="${TMP_DIR}/reports"
    export Hub__PollInterval="00:00:02"
    export Hub__HttpTimeout="00:00:02"
    export Hub__UpdateCheck__Enabled="false"
    export Hub__Sources__0__Id="${SOURCE}" Hub__Sources__0__Name="lab daemon" Hub__Sources__0__Environment="lab"
    # A closed port: everything the Hub holds comes from the push.
    export Hub__Sources__0__BaseUrl="http://127.0.0.1:${CLOSED_PORT}"
    export Hub__Sources__0__ImportApiKey="${IMPORT_KEY}"
    for kv in "$@"; do export "${kv?}"; done
    exec dotnet "$(basename "${HUB_DLL}")"
  ) >> "${TMP_DIR}/hub.log" 2>&1 &
  HUB_PID=$!
  disown "${HUB_PID}" 2>/dev/null || true
  wait_http "${HUB_URL}/health/ready" "the Hub"
}
stop_hub() {
  kill -TERM "${HUB_PID}" 2>/dev/null || true
  for _ in $(seq 1 60); do
    kill -0 "${HUB_PID}" 2>/dev/null || { HUB_PID=""; return 0; }
    sleep 0.25
  done
  die "the Hub still alive 15 s after SIGTERM"
}
mkdir -p "${TMP_DIR}/reports"

step "Phase 1: the daemon and a Hub that trusts X-Forwarded-User"
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" >> "${TMP_DIR}/daemon.log" 2>&1 &
PIDS+=($!); disown "$!" 2>/dev/null || true
wait_http "http://127.0.0.1:${D_HTTP}/api/status" "the daemon"
start_hub Hub__AckRelay__TrustIdentityHeader=true
HUB_VERSION="$(curl -fsS "${HUB_URL}/api/status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version", "?"))')"
CODE="$(req probe GET "/api/recap?period=day")"
[ "${CODE}" = "404" ] && die "GET /api/recap is a 404: Hub ${HUB_VERSION} has no recap (0.9.0 and later)"
ok "Hub ${HUB_VERSION} on ${HUB_URL}"

# --- load ----------------------------------------------------------------------
cat > "${TMP_DIR}/build_payload.py" <<'PY'
import sys, time
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

out, service, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = time.time_ns()

def kv(k, v):
    return common.KeyValue(key=k, value=common.AnyValue(string_value=v))

def n1_trace(tid, route, table):
    # One HTTP root and six SELECTs differing only by id: one n_plus_one_sql per route.
    trace_id = tid.to_bytes(16, "big")
    root = (1).to_bytes(8, "big")
    spans = [trace.Span(trace_id=trace_id, span_id=root, name="GET " + route,
                        kind=trace.Span.SPAN_KIND_SERVER,
                        start_time_unix_nano=now, end_time_unix_nano=now + 50_000_000,
                        attributes=[kv("http.route", route)])]
    for i in range(6):
        start = now + (i + 1) * 1_000_000
        spans.append(trace.Span(
            trace_id=trace_id, span_id=(i + 2).to_bytes(8, "big"), parent_span_id=root,
            name="SELECT", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=start, end_time_unix_nano=start + 500_000,
            attributes=[kv("db.system", "postgresql"),
                        kv("db.statement", "SELECT * FROM %s WHERE id = %d" % (table, i + 1))]))
    return spans

spans = [s for t in range(count) for s in n1_trace(1000 + t, "/api/orders", "orders")]
spans += [s for t in range(count) for s in n1_trace(2000 + t, "/api/invoices", "invoices")]
rs = trace.ResourceSpans(
    resource=resource.Resource(attributes=[kv("service.name", service)]),
    scope_spans=[trace.ScopeSpans(spans=spans)])
open(out, "wb").write(svc.ExportTraceServiceRequest(resource_spans=[rs]).SerializeToString())
PY
step "Post ${K} N+1 traces on /api/orders and ${K} on /api/invoices"
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/load.pb" "${SVC}" "${K}"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "http://127.0.0.1:${D_HTTP}/v1/traces" \
  -H 'Content-Type: application/x-protobuf' --data-binary @"${TMP_DIR}/load.pb")"
[ "${CODE}" = "200" ] || die "OTLP POST answered ${CODE}"

# Prints "<orders sig> <invoices sig> <orders extra io> <day gco2> <day avoidable io>" once both are counted.
DAEMON=""
for _ in $(seq 1 40); do
  DAEMON="$(curl -fsS "http://127.0.0.1:${D_HTTP}/api/detections?limit=5000" | python3 -c '
import json, sys
p, k, svc, today = json.load(sys.stdin), int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
rows = {r["signature"]: r for r in p["counts"] if r["signature"].startswith("n_plus_one_sql:" + svc + ":")}
o = [r for s, r in rows.items() if ":_api_orders:" in s]
i = [r for s, r in rows.items() if ":_api_invoices:" in s]
day = next((d for d in p["days"] if d["day"] == today), {})
if o and i and o[0]["detections"] == k and i[0]["detections"] == k and day.get("avoidable_gco2") is not None:
    print(o[0]["signature"], i[0]["signature"], o[0]["extra_io_ops"], repr(day["avoidable_gco2"]), day["avoidable_io_ops"], p["ledger_id"])
' "${K}" "${SVC}" "${TODAY}" 2>/dev/null || true)"
  [ -n "${DAEMON}" ] && break
  sleep 0.5
done
[ -n "${DAEMON}" ] || die "the daemon never counted ${K} of each N+1 with a day carbon (is it 0.38.0 with [green] on?)"
read -r SIG_O SIG_I EXTRA_O DAY_GCO2 DAY_AVOID DAEMON_LEDGER <<< "${DAEMON}"
WANT_CO2="$(python3 -c 'import sys; e,g,a = int(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]); print(float("%.0e" % (e * g / a)))' \
  "${EXTRA_O}" "${DAY_GCO2}" "${DAY_AVOID}")"
ok "daemon counts ${K} + ${K}; today ${DAY_GCO2} g over ${DAY_AVOID} avoidable I/O, /api/orders ${EXTRA_O} extra I/O, so ${WANT_CO2} g"

# --- R1 --------------------------------------------------------------------------
step "R1 the Hub prices the planted N+1 at the daemon's day coefficient"
# The daemon pushes its ledger at most once a minute.
R1=""
for _ in $(seq 1 60); do
  CODE="$(req r1 GET "/api/recap?period=day")"
  if [ "${CODE}" = "200" ]; then
    R1="$(py 'r = j("r1")
p = next((p for p in r["priorities"] if p.get("signature") == sys.argv[3]), None)
if p and p["co2_grams"] is not None:
    print(p["volume_known"], p["avoidable_io_ops"], repr(p["co2_grams"]), p["co2_partial"],
          r["tiles"].get("co2_missing_reason"), p["rank"])' "${SIG_O}" 2>/dev/null || true)"
    [ -n "${R1}" ] && break
  fi
  sleep 2
done
[ -n "${R1}" ] || die "R1 no priced priority for ${SIG_O} after 2 minutes (last: HTTP ${CODE} $(head -c 600 "${TMP_DIR}/r1.body"))"
read -r R1_KNOWN R1_IO R1_CO2 R1_PARTIAL R1_MISSING R1_RANK <<< "${R1}"
[ "${R1_KNOWN}" = "True" ] || die "R1 volume_known=${R1_KNOWN}"
[ "${R1_IO}" = "${EXTRA_O}" ] || die "R1 the priority's avoidable I/O is ${R1_IO}, the daemon counted ${EXTRA_O}"
[ "${R1_PARTIAL}" = "False" ] || die "R1 co2_partial=${R1_PARTIAL}"
[ "${R1_MISSING}" = "None" ] || die "R1 the tiles carry co2_missing_reason=${R1_MISSING}"
python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= 1e-12 else 1)' "${R1_CO2}" "${WANT_CO2}" \
  || die "R1 the Hub serves ${R1_CO2} g, the daemon's coefficient gives ${WANT_CO2} g"
ok "rank ${R1_RANK}, ${R1_IO} avoidable I/O, ${R1_CO2} g = ${WANT_CO2} g, no missing reason"

step "Push the sealed day a previous instance would have pushed for ${YESTERDAY_ISO}"
python3 - "${SIG_O}" "${SIG_I}" "${YESTERDAY}" "${K}" > "${TMP_DIR}/yesterday.json" <<'PY'
import json, sys, uuid
sig_o, sig_i, day, k = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
extra = (k - 2) * 5
print(json.dumps({
    "ledger_id": str(uuid.uuid4()), "started_ms": day * 86_400_000 + 3_600_000,
    "current_day": day, "oldest_day": day, "sealed_through": day, "next_after": None,
    "counts": [{"day": day, "signature": s, "detections": k - 2, "extra_io_ops": extra} for s in (sig_o, sig_i)],
    "days": [{"day": day, "sealed": True, "gap": False, "overflow_detections": 0, "overflow_extra_io_ops": 0,
              "shed_traces": 0, "ingest_rejected": 0, "sampling_rate": 1.0,
              "avoidable_gco2": 2.3e-06 * 2 * extra, "avoidable_gco2_low": 1.15e-06 * 2 * extra,
              "avoidable_io_ops": 2 * extra, "total_io_ops": 2 * (k - 2) * 6}],
}))
PY
CODE="$(req yday POST "/api/import/detections?source_id=${SOURCE}" -H "X-API-Key: ${IMPORT_KEY}" \
  -H 'Content-Type: application/json' --data-binary @"${TMP_DIR}/yesterday.json")"
case "${CODE}" in 2*) ;; *) die "the yesterday page import answered ${CODE}: $(head -c 400 "${TMP_DIR}/yday.body")" ;; esac
ok "ledger day ${YESTERDAY_ISO} imported sealed (HTTP ${CODE})"

# --- R2 --------------------------------------------------------------------------
step "R2 an action needs a caller the Hub can name"
ACTION="{\"signature\":\"${SIG_O}\",\"take\":true}"
CODE="$(req r2-anon POST /api/actions -H 'Content-Type: application/json' --data "${ACTION}")"
expect_code "R2 POST /api/actions without an identity" "${CODE}" 403 r2-anon
ok "no identity: 403"
CODE="$(req r2 POST /api/actions -H 'Content-Type: application/json' -H "X-Forwarded-User: ${OWNER}" --data "${ACTION}")"
expect_code "R2 POST /api/actions as ${OWNER}" "${CODE}" 201 r2
R2_OWNER="$(py 'a = j("r2"); print(a["status"], a["owner"])')"
[ "${R2_OWNER}" = "in_progress ${OWNER}" ] || die "R2 the action reads '${R2_OWNER}'"
CODE="$(req r2-recap GET "/api/recap?period=day")"
expect_code "R2 recap" "${CODE}" 200 r2-recap
R2_RECAP="$(py 'r = j("r2-recap")
p = next(p for p in r["priorities"] if p.get("signature") == sys.argv[3])
a = p["action"] or {}
print(a.get("status"), a.get("owner"), r["tiles"]["actions"]["in_progress"])' "${SIG_O}")"
[ "${R2_RECAP}" = "in_progress ${OWNER} 1" ] || die "R2 the recap reads the action as '${R2_RECAP}'"
ok "201, the recap carries in_progress by ${OWNER}, tiles.actions.in_progress 1"

# --- R3 --------------------------------------------------------------------------
step "R3 labels name the endpoint and the service"
LABEL="{\"service\":\"${SVC}\",\"endpoint\":\"/api/orders\",\"label\":\"${ENDPOINT_LABEL}\"}"
CODE="$(req r3-anon PUT /api/labels -H 'Content-Type: application/json' --data "${LABEL}")"
expect_code "R3 PUT /api/labels without an identity" "${CODE}" 403 r3-anon
CODE="$(req r3-ep PUT /api/labels -H 'Content-Type: application/json' -H "X-Forwarded-User: ${OWNER}" --data "${LABEL}")"
expect_code "R3 PUT /api/labels" "${CODE}" 204 r3-ep
CODE="$(req r3-svc PUT /api/labels/services -H 'Content-Type: application/json' -H "X-Forwarded-User: ${OWNER}" \
  --data "{\"service\":\"${SVC}\",\"label\":\"${SERVICE_LABEL}\"}")"
expect_code "R3 PUT /api/labels/services" "${CODE}" 204 r3-svc
CODE="$(req r3 GET "/api/recap?period=day&view=pilotage")"
expect_code "R3 pilotage recap" "${CODE}" 200 r3
R3="$(py 'r = j("r3")
tech = {"signature", "template", "suggestion", "suggested_fix", "code_location", "confidence", "events"}
leak = sorted(tech & set(keys(r)))
rows = r["priorities"]
named = [p for p in rows if p["label"] == sys.argv[3]]
unnamed = [p for p in rows if p["label"] is None]
assert r["view"] == "pilotage", r["view"]
assert len(named) == 1 and len(unnamed) == 1, rows
assert all(p["service_label"] == sys.argv[4] for p in rows), [p["service_label"] for p in rows]
assert "endpoint" not in named[0], named[0]
assert unnamed[0].get("endpoint") == "/api/invoices", unnamed[0]
print(",".join(leak) or "none")' "${ENDPOINT_LABEL}" "${SERVICE_LABEL}")" || die "R3 the pilotage rows: see above"
[ "${R3}" = "none" ] || die "R3 the pilotage JSON carries technical keys: ${R3}"
ok "403 without identity, 204 twice; '${ENDPOINT_LABEL}' and '${SERVICE_LABEL}' on the rows, no technical key"

# --- R4 --------------------------------------------------------------------------
step "R4 an on-demand report of ${YESTERDAY_ISO}"
CODE="$(req r4 POST /api/recap/reports -H 'Content-Type: application/json' -H "X-Forwarded-User: ${OWNER}" \
  --data '{"period":"day"}')"
expect_code "R4 POST /api/recap/reports" "${CODE}" 201 r4
R4="$(py 'r = j("r4")
assert re.fullmatch(r"[0-9a-f]{32}", r["id"]), r
assert r["subscription"] is None and r["created_by"] == sys.argv[3], r
assert r["period"]["from"] == sys.argv[4] == r["period"]["to"], r
assert sorted(r["views"]) == ["pilotage", "tech"] and r["deliveries"] == [], r
print(r["id"], r["nothing_moved"], r["complete"])' "${OWNER}" "${YESTERDAY_ISO}")" || die "R4 the report item: see above"
read -r REPORT_ID R4_NOTHING R4_COMPLETE <<< "${R4}"
CODE="$(req r4-list GET /api/recap/reports -H "X-Forwarded-User: ${OWNER}")"
expect_code "R4 GET /api/recap/reports" "${CODE}" 200 r4-list
py 'assert any(r["id"] == sys.argv[3] for r in j("r4-list")), "not listed"' "${REPORT_ID}" \
  || die "R4 ${REPORT_ID} is not in the list"
for view in pilotage tech; do
  CODE="$(req "page-${view}" GET "/recaps/${REPORT_ID}/${view}.html" -H "X-Forwarded-User: ${OWNER}")"
  expect_code "R4 /recaps/${REPORT_ID}/${view}.html" "${CODE}" 200 "page-${view}"
  CSP="$(hdr "page-${view}" content-security-policy)"
  CTYPE="$(hdr "page-${view}" content-type)"
  [ -n "${CSP}" ] || die "R4 ${view}.html has no Content-Security-Policy"
  case "${CTYPE}" in text/html*) ;; *) die "R4 ${view}.html is ${CTYPE}" ;; esac
  # Self-contained: nothing loaded from elsewhere. A plain <a href> is a link, not a load.
  LOADS="$(py 'h = body(sys.argv[3])
pat = r"<script[^>]*\bsrc=|<link\b[^>]*\bhref=|<(?:img|iframe|source|video|audio|embed|object)\b[^>]*\b(?:src|data)=\s*[\"\x27]?(?:https?:)?//|@import|url\(\s*[\"\x27]?(?:https?:)?//"
print(len(re.findall(pat, h, re.I)))' "page-${view}")"
  [ "${LOADS}" = "0" ] || die "R4 ${view}.html loads ${LOADS} external resources"
done
ok "report ${REPORT_ID} (nothing_moved ${R4_NOTHING}, complete ${R4_COMPLETE}) listed; both pages 200 text/html with a CSP, no external load"

# --- R5 --------------------------------------------------------------------------
step "R5 the management page names people and steps in business words"
R5="$(py 'p, t = body("page-pilotage"), body("page-tech")
text = no_style(p)
checks = {
    "an @ outside the stylesheet": "@" not in text,
    "no e-mail anywhere": not EMAIL.search(p),
    "the unnamed step": ("An unnamed step in " + sys.argv[4]) in p,
    "the endpoint label": sys.argv[5] in p,
    "the owner by name": sys.argv[3] in p,
    "no /api/invoices": "/api/invoices" not in p,
    "no /api/orders": "/api/orders" not in p,
    "no SQL template": "SELECT" not in p,
    "the tech page keeps /api/invoices": "/api/invoices" in t,
}
bad = [k for k, v in checks.items() if not v]
print("; ".join(bad) or "ok")' "${OWNER_NAME}" "${SERVICE_LABEL}" "${ENDPOINT_LABEL}")"
[ "${R5}" = "ok" ] || die "R5 the management page fails: ${R5}"
ok "'An unnamed step in ${SERVICE_LABEL}', '${OWNER_NAME}', no @ outside <style>, no e-mail, no endpoint or SQL; the tech page keeps /api/invoices"

# --- R6, R7 ----------------------------------------------------------------------
step "Phase 2: a daily subscription, its webhook and its e-mail"
python3 "${TMP_DIR}/hook.py" "${HOOK_PORT}" "${TMP_DIR}/hook" &
PIDS+=($!); disown "$!" 2>/dev/null || true
python3 "${TMP_DIR}/smtp.py" "${SMTP_PORT}" "${TMP_DIR}/mail" &
PIDS+=($!); disown "$!" 2>/dev/null || true
stop_hub
start_hub \
  Hub__AckRelay__TrustIdentityHeader=true \
  Hub__Recaps__PublicUrl="${HUB_URL}" \
  Hub__Recaps__Webhooks__0__Name=hrc-hook \
  Hub__Recaps__Webhooks__0__Url="http://127.0.0.1:${HOOK_PORT}/recap" \
  Hub__Recaps__Webhooks__0__Secret="${HOOK_SECRET}" \
  Hub__Recaps__Webhooks__0__Confidentiality=public \
  Hub__Recaps__Smtp__Host=127.0.0.1 \
  Hub__Recaps__Smtp__Port="${SMTP_PORT}" \
  Hub__Recaps__Smtp__StartTls=false \
  Hub__Recaps__Smtp__From=recap@lab.example \
  Hub__Recaps__Subscriptions__0__Name=hrc-daily \
  Hub__Recaps__Subscriptions__0__Cadences__0=day \
  Hub__Recaps__Subscriptions__0__Views__0=pilotage \
  Hub__Recaps__Subscriptions__0__Views__1=tech \
  Hub__Recaps__Subscriptions__0__Webhooks__0=hrc-hook \
  Hub__Recaps__Subscriptions__0__Emails__0="${MAIL_TO}"
ok "Hub restarted with subscription hrc-daily (day, both views, webhook hrc-hook, ${MAIL_TO})"

# The loop ticks every 15 s: one tick freezes yesterday, the same pass delivers it.
HOOK_RAW=""; MAIL_EML=""
for _ in $(seq 1 60); do
  HOOK_RAW="$(ls "${TMP_DIR}"/hook/*.raw 2>/dev/null | head -1 || true)"
  MAIL_EML="$(ls "${TMP_DIR}"/mail/*.eml 2>/dev/null | head -1 || true)"
  [ -n "${HOOK_RAW}" ] && [ -n "${MAIL_EML}" ] && break
  sleep 1
done
# The sink answers before the Hub records the delivery: wait for both states to settle.
SUBS="none"
for _ in $(seq 1 20); do
  req subs GET /api/recap/reports -H "X-Forwarded-User: ${OWNER}" >/dev/null || true
  SUBS="$(py 'r = next((r for r in j("subs") if r["subscription"] == "hrc-daily"), None)
print("none" if r is None else "%s %s %s %s" % (r["id"], r["period"]["from"], r["nothing_moved"],
      ",".join(sorted("%s:%s" % (d["channel"], d["state"]) for d in r["deliveries"]))))' 2>/dev/null || echo "unreadable")"
  case "${SUBS}" in none|unreadable|*pending*) sleep 1 ;; *) break ;; esac
done
[ -n "${HOOK_RAW}" ] || die "R6 no webhook POST within 60 s (subscription report: ${SUBS}; hub log: $(grep -E '25[0-9]{2}' "${TMP_DIR}/hub.log" | tail -3))"
read -r SUB_ID SUB_FROM SUB_NOTHING SUB_DELIVERIES <<< "${SUBS}"
[ "${SUB_FROM}" = "${YESTERDAY_ISO}" ] || die "R6 the subscription froze ${SUB_FROM}, want ${YESTERDAY_ISO}"

step "R6 the webhook is signed and carries the management view only"
R6="$(python3 - "${HOOK_RAW}" "${HOOK_RAW%.raw}.json" "${HOOK_SECRET}" "${SUB_ID}" "${YESTERDAY_ISO}" "${HUB_URL}" <<'PY'
import hashlib, hmac, json, sys, time
raw = open(sys.argv[1], "rb").read()
meta = json.load(open(sys.argv[2]))
secret, rid, day, hub = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
h = {k.lower(): v for k, v in meta["headers"].items()}
ts, sig = h.get("x-perfsentinel-timestamp", ""), h.get("x-perfsentinel-signature", "")
want = "sha256=" + hmac.new(secret.encode(), ts.encode() + b"." + raw, hashlib.sha256).hexdigest()
wrong = "sha256=" + hmac.new(b"x" * 48, ts.encode() + b"." + raw, hashlib.sha256).hexdigest()
b = json.loads(raw)
def keys(o):
    if isinstance(o, dict):
        for k, v in o.items():
            yield k
            yield from keys(v)
    elif isinstance(o, list):
        for v in o:
            yield from keys(v)
tech = {"signature", "template", "suggestion", "suggested_fix", "code_location", "confidence", "events", "endpoint"}
checks = {
    "signature verifies": hmac.compare_digest(sig, want),
    "another secret does not": not hmac.compare_digest(sig, wrong),
    "fresh timestamp": ts.isdigit() and abs(time.time() - int(ts)) < 600,
    "event recap": b["event"] == "recap" and b["subscription"] == "hrc-daily" and b["report_id"] == rid,
    "period": b["period"] == {"kind": "day", "from": day, "to": day},
    "pilotage_url": b["pilotage_url"] == f"{hub}/recaps/{rid}/pilotage.html",
    "tech_url": b["tech_url"] == f"{hub}/recaps/{rid}/tech.html",
    "pilotage view": b["recap"]["view"] == "pilotage",
    "no technical key": not (tech & set(keys(b["recap"]))),
    "no @": b"@" not in raw,
    "priorities": len(b["recap"]["priorities"]) == 2,
}
bad = [k for k, v in checks.items() if not v]
print("; ".join(bad) or "ok", len(raw))
PY
)"
read -r R6_VERDICT R6_BYTES <<< "${R6}"
[ "${R6_VERDICT}" = "ok" ] || die "R6 the webhook fails: ${R6}"
case ",${SUB_DELIVERIES}," in *,webhook:delivered,*) ;; *) die "R6 the report's deliveries read ${SUB_DELIVERIES}" ;; esac
ok "report ${SUB_ID} of ${SUB_FROM}: ${R6_BYTES} bytes, HMAC-SHA256 verifies, management view only, no @, webhook delivered"

step "R7 the e-mail carries the management page"
[ -n "${MAIL_EML}" ] || die "R7 no message reached the SMTP sink within 60 s (deliveries: ${SUB_DELIVERIES})"
R7="$(python3 - "${MAIL_EML}" "${MAIL_EML%.eml}.rcpt" "${MAIL_TO}" "${YESTERDAY_ISO}" "${SERVICE_LABEL}" <<'PY'
import email, re, sys
from email import policy
msg = email.message_from_bytes(open(sys.argv[1], "rb").read(), policy=policy.default)
rcpt, to, day, svc = open(sys.argv[2]).read().split(), sys.argv[3], sys.argv[4], sys.argv[5]
parts = [p for p in msg.iter_attachments()]
html = [p for p in parts if p.get_filename() == f"perf-sentinel-recap-{day}-pilotage.html"]
page = html[0].get_content() if html else ""
if isinstance(page, bytes):
    page = page.decode("utf-8")
text = re.sub(r"(?is)<style\b.*?</style>", "", page)
body = msg.get_body(preferencelist=("plain",))
checks = {
    "recipient": rcpt == [to],
    "one attachment, the pilotage page": len(parts) == 1 and len(html) == 1,
    "text/html": bool(html) and html[0].get_content_type() == "text/html",
    "no @ outside the stylesheet": bool(page) and "@" not in text,
    "the unnamed step": ("An unnamed step in " + svc) in page,
    "the tech link in the body": body is not None and "/tech.html" in body.get_content(),
}
bad = [k for k, v in checks.items() if not v]
print("; ".join(bad) or "ok", len(page), msg["Subject"].replace(" ", "_"))
PY
)"
read -r R7_VERDICT R7_BYTES R7_SUBJECT <<< "${R7}"
[ "${R7_VERDICT}" = "ok" ] || die "R7 the e-mail fails: ${R7}"
case ",${SUB_DELIVERIES}," in *,email:delivered,*) ;; *) die "R7 the report's deliveries read ${SUB_DELIVERIES}" ;; esac
ok "'${R7_SUBJECT//_/ }' to ${MAIL_TO}, one ${R7_BYTES}-character pilotage attachment, no @ outside <style>, email delivered"

# --- R8 --------------------------------------------------------------------------
step "Phase 3: access control, alice (member) and bob (reader)"
hash_pw() {
  (cd "$(dirname "${HUB_DLL}")" && printf '%s\n' "$1" | dotnet "$(basename "${HUB_DLL}")" hash-password)
}
ALICE_PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
BOB_PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
ALICE_HASH="$(hash_pw "${ALICE_PW}")"
BOB_HASH="$(hash_pw "${BOB_PW}")"
case "${ALICE_HASH}${BOB_HASH}" in '$pbkdf2-sha256$'*'$pbkdf2-sha256$'*) ;; *) die "hash-password printed '${ALICE_HASH}'" ;; esac
stop_hub
# The provider is never called: local accounts sign in without it, but Hub:Auth must name one.
# Access on wants an admin (a provider identity no one signs in as here) and /metrics on a port of its own.
start_hub \
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
  [ "${code}" = "302" ] || die "R8 local sign-in of $1: HTTP ${code}"
  awk 'tolower($1) == "set-cookie:" && $2 ~ /^hub_session=/ { sub(/;.*/, "", $2); print $2; exit }' "${TMP_DIR}/signin-$1.hdr"
}
ALICE="$(sign_in alice "${ALICE_PW}")"
BOB="$(sign_in bob "${BOB_PW}")"
[ -n "${ALICE}" ] && [ -n "${BOB}" ] || die "R8 a local sign-in set no hub_session"
ok "alice and bob signed in with local accounts"

step "R8 a report alice generated is a 404 to bob"
CODE="$(req r8-anon GET /api/recap/reports)"
expect_code "R8 the list without a session" "${CODE}" 401 r8-anon
CODE="$(req r8-gen POST /api/recap/reports -H "Cookie: ${ALICE}" -H 'Sec-Fetch-Site: same-origin' \
  -H 'Content-Type: application/json' --data '{"period":"day"}')"
expect_code "R8 alice generates" "${CODE}" 201 r8-gen
ALICE_ID="$(py 'print(j("r8-gen")["id"])')"
CODE="$(req r8-alice GET "/api/recap/reports/${ALICE_ID}" -H "Cookie: ${ALICE}")"
expect_code "R8 alice reads her report" "${CODE}" 200 r8-alice
CODE="$(req r8-alice-page GET "/recaps/${ALICE_ID}/pilotage.html" -H "Cookie: ${ALICE}")"
expect_code "R8 alice reads her page" "${CODE}" 200 r8-alice-page
# bob reads the findings: his 404 below is the report rule, not a missing findings.read.
CODE="$(req r8-bob-recap GET "/api/recap?period=day" -H "Cookie: ${BOB}")"
expect_code "R8 bob reads the recap" "${CODE}" 200 r8-bob-recap
CODE="$(req r8-bob GET "/api/recap/reports/${ALICE_ID}" -H "Cookie: ${BOB}")"
expect_code "R8 bob reads alice's report" "${CODE}" 404 r8-bob
CODE="$(req r8-bob-unknown GET "/api/recap/reports/$(python3 -c 'import secrets; print(secrets.token_hex(16))')" -H "Cookie: ${BOB}")"
expect_code "R8 bob reads an unknown id" "${CODE}" 404 r8-bob-unknown
cmp -s "${TMP_DIR}/r8-bob.body" "${TMP_DIR}/r8-bob-unknown.body" \
  || die "R8 bob's 404 differs from an unknown id's: '$(cat "${TMP_DIR}/r8-bob.body")' vs '$(cat "${TMP_DIR}/r8-bob-unknown.body")'"
for view in pilotage tech; do
  CODE="$(req "r8-bob-${view}" GET "/recaps/${ALICE_ID}/${view}.html" -H "Cookie: ${BOB}")"
  expect_code "R8 bob opens alice's ${view} page" "${CODE}" 404 "r8-bob-${view}"
done
CODE="$(req r8-bob-sub GET "/api/recap/reports/${SUB_ID}" -H "Cookie: ${BOB}")"
expect_code "R8 bob reads the subscription report" "${CODE}" 404 r8-bob-sub
CODE="$(req r8-bob-list GET /api/recap/reports -H "Cookie: ${BOB}")"
expect_code "R8 bob lists" "${CODE}" 200 r8-bob-list
CODE="$(req r8-alice-list GET /api/recap/reports -H "Cookie: ${ALICE}")"
expect_code "R8 alice lists" "${CODE}" 200 r8-alice-list
R8_LISTS="$(py 'print(len(j("r8-bob-list")), ",".join(r["id"] == sys.argv[3] and "own" or "other" for r in j("r8-alice-list")))' "${ALICE_ID}")"
[ "${R8_LISTS}" = "0 own" ] || die "R8 bob lists / alice lists read '${R8_LISTS}', want '0 own'"
ok "401 anonymous; alice 201 then 200 (report and page); bob reads the recap (200) but gets 404 on her report, both pages and the subscription report, the same body as an unknown id; bob lists 0, alice her own"

{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Daemon: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo "- Hub: ${HUB_DLL} (${HUB_VERSION})"
  echo "- Today ${TODAY}, yesterday ${YESTERDAY_ISO} (UTC)"
  echo ""
  echo "| id | check | result |"
  echo "|---|---|---|"
  echo "| R1 | day carbon in the recap | ${R1_IO} avoidable I/O, ${R1_CO2} g = ${EXTRA_O} x ${DAY_GCO2} / ${DAY_AVOID} at one significant figure |"
  echo "| R2 | actions need an identity | 403 anonymous, 201 as ${OWNER}, recap in_progress by ${OWNER} |"
  echo "| R3 | labels in the pilotage view | '${ENDPOINT_LABEL}' and '${SERVICE_LABEL}', no technical key |"
  echo "| R4 | on-demand report | ${REPORT_ID}, listed, both pages 200 with a CSP, no external load |"
  echo "| R5 | management page | '${OWNER_NAME}', 'An unnamed step in ${SERVICE_LABEL}', no @ outside <style>, no endpoint |"
  echo "| R6 | signed webhook | report ${SUB_ID}, HMAC verifies, management view only, no @ |"
  echo "| R7 | e-mail | pilotage attachment, no @ outside <style>, ${SUB_DELIVERIES} |"
  echo "| R8 | reports under access control | bob 404 on alice's report and pages, the unknown-id body |"
  echo ""
  echo "Checks: ${CHECKS}"
  echo ""
  echo "Verdict: **PASS**"
} > "${REPORT}"
color_green "PASS, ${CHECKS} checks, report at ${REPORT}"
