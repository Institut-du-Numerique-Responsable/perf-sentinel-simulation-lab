#!/usr/bin/env bash
# hub-detection-volume: the Hub 0.8.6 detection volume, end to end, from two
# loopback daemons on the 0.37.0 binary to a windowed GET /api/findings.
#
# A local PerfSentinelHub process (a Release build, no cluster, no Docker)
# knows three sources, all named in the Hub's configuration:
#   hdv-poll  daemon A, polled directly, no push
#   hdv-push  daemon B, pushing to the Hub, its BaseUrl a closed port
#   hdv-pods  daemons A and B behind one address: a loopback proxy that moves
#             to the other daemon on each /api/status, two pods behind a Service
# Every daemon receives the same N+1, so the Hub holds one signature.
#
#   H1 the same total through poll and push: hdv-poll and hdv-push both serve
#      exactly K1 detections for the same load.
#   H2 an exact total over a restart: daemon A restarts (a new ledger) and
#      takes K2 more, its own ledger counts K2, the Hub serves K1 + K2 for
#      hdv-poll with `restart` in its reasons and no `multi_instance`.
#   H3 multi_instance: hdv-pods reads two ledgers alive at once and says so,
#      hdv-push does not.
#   H4 the finding's count is the sum of its sources, and incomplete.
#   H5 a read without from or to carries none of the seven new names.
#   H6 perf_sentinel_hub_detection_reads_total counts the poll's passes.
#
# On Hub 0.8.5 the windowed read carries no `detections` and H1 fails.
set -euo pipefail

SCENARIO="hub-detection-volume"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
rm -f "${REPORT}"  # die() prints it, never show a previous run's verdict
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCENARIO}.XXXXXX")"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
PERF_SENTINEL_HUB_REPO_PATH="${PERF_SENTINEL_HUB_REPO_PATH:-${HOME}/RiderProjects/PerfSentinelHub}"
HUB_DLL="${PERF_SENTINEL_HUB_DLL:-${PERF_SENTINEL_HUB_REPO_PATH}/PerfSentinelHub/bin/Release/net10.0/PerfSentinelHub.dll}"
BASE_PORT="${HDV_BASE_PORT:-14960}"
HUB_PORT="${BASE_PORT}"
A_HTTP=$((BASE_PORT + 1)); A_GRPC=$((BASE_PORT + 2))
B_HTTP=$((BASE_PORT + 3)); B_GRPC=$((BASE_PORT + 4))
PROXY_PORT=$((BASE_PORT + 5))
CLOSED_PORT=$((BASE_PORT + 6))
HUB_URL="http://127.0.0.1:${HUB_PORT}"
K1="${HDV_K1:-8}"
K2="${HDV_K2:-5}"
IMPORT_KEY="$(python3 -c 'print("h" * 40)')"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

PIDS=()
A_PID=""
cleanup() {
  [ -n "${A_PID}" ] && kill "${A_PID}" 2>/dev/null
  for pid in "${PIDS[@]}"; do kill "${pid}" 2>/dev/null; done
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

step "Prerequisites"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no daemon binary at ${PERF_SENTINEL_LOCAL_BIN}"
[ -f "${HUB_DLL}" ] || die "no Hub build at ${HUB_DLL} (dotnet build PerfSentinelHub.sln -c Release, or set PERF_SENTINEL_HUB_DLL)"
command -v dotnet >/dev/null || die "dotnet not on PATH, the Hub runs as a local process"
python3 -c 'import opentelemetry.proto' 2>/dev/null \
  || die "the OTLP payload needs opentelemetry-proto: pip install opentelemetry-proto"
for port in "${HUB_PORT}" "${A_HTTP}" "${B_HTTP}" "${PROXY_PORT}" "${CLOSED_PORT}"; do
  python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1)" "${port}" 2>/dev/null \
    && die "port ${port} already answers, stop that process or set HDV_BASE_PORT"
done
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
ok "daemons: ${PERF_SENTINEL_LOCAL_BIN} ${BIN_VERSION}"
ok "Hub: ${HUB_DLL}"

# --- daemons ---------------------------------------------------------------
daemon_toml() {  # $1 = name, $2 = http port, $3 = grpc port, $4 = push source id or empty
  cat > "${TMP_DIR}/$1.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = $2
listen_port_grpc = $3
api_enabled = true
trace_ttl_ms = 1000
findings_stdout = false

# Never the operator's own ack store.
[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
EOF
  if [ -n "$4" ]; then
    cat >> "${TMP_DIR}/$1.toml" <<EOF

[daemon.hub_export]
enabled = true
endpoint = "${HUB_URL}/api/import/findings"
source_id = "$4"
api_key_file = "${TMP_DIR}/hub.key"
flush_interval_secs = 1
EOF
  fi
}
printf '%s' "${IMPORT_KEY}" > "${TMP_DIR}/hub.key"
chmod 600 "${TMP_DIR}/hub.key"
daemon_toml a "${A_HTTP}" "${A_GRPC}" ""
daemon_toml b "${B_HTTP}" "${B_GRPC}" "hdv-push"

start_a() {
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/a.toml" >> "${TMP_DIR}/a.log" 2>&1 &
  A_PID=$!
  disown "${A_PID}" 2>/dev/null || true
  wait_http "http://127.0.0.1:${A_HTTP}/api/status" "daemon A"
}
stop_a() {  # SIGTERM, the graceful drain of a rollout
  kill -TERM "${A_PID}" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "${A_PID}" 2>/dev/null || { A_PID=""; return 0; }
    sleep 0.25
  done
  die "daemon A still alive 10 s after SIGTERM"
}

# --- the proxy that stands for a Service over two pods ---------------------
cat > "${TMP_DIR}/proxy.py" <<'PROXY'
import sys, threading, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port, targets = int(sys.argv[1]), sys.argv[2:]
state = {"i": 0}
lock = threading.Lock()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            # A poll pass starts with /api/status: each pass lands on the other pod.
            if self.path.startswith("/api/status"):
                state["i"] = (state["i"] + 1) % len(targets)
            target = targets[state["i"]]
        req = urllib.request.Request(target + self.path)
        for h in ("X-API-Key", "Authorization", "Accept"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                code, body, ctype = r.status, r.read(), r.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            code, body, ctype = e.code, e.read(), e.headers.get("Content-Type", "text/plain")
        except Exception:
            code, body, ctype = 502, b"pod down", "text/plain"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PROXY

# --- the Hub -----------------------------------------------------------------
start_hub() {
  mkdir -p "${TMP_DIR}/reports"
  # The content root is the build directory, so its appsettings.json applies, then these.
  (
    cd "$(dirname "${HUB_DLL}")"
    export ASPNETCORE_URLS="${HUB_URL}"
    export Hub__DatabasePath="${TMP_DIR}/hub.db"
    export Hub__Analysis__ReportDirectory="${TMP_DIR}/reports"
    export Hub__PollInterval="00:00:02"
    export Hub__HttpTimeout="00:00:02"
    export Hub__UpdateCheck__Enabled="false"
    export Hub__Sources__0__Id="hdv-poll" Hub__Sources__0__Name="poll" Hub__Sources__0__Environment="lab"
    export Hub__Sources__0__BaseUrl="http://127.0.0.1:${A_HTTP}"
    export Hub__Sources__1__Id="hdv-push" Hub__Sources__1__Name="push" Hub__Sources__1__Environment="lab"
    export Hub__Sources__1__BaseUrl="http://127.0.0.1:${CLOSED_PORT}"
    export Hub__Sources__1__ImportApiKey="${IMPORT_KEY}"
    export Hub__Sources__2__Id="hdv-pods" Hub__Sources__2__Name="pods" Hub__Sources__2__Environment="lab"
    export Hub__Sources__2__BaseUrl="http://127.0.0.1:${PROXY_PORT}"
    exec dotnet "$(basename "${HUB_DLL}")"
  ) >> "${TMP_DIR}/hub.log" 2>&1 &
  PIDS+=($!)
  disown "$!" 2>/dev/null || true
  wait_http "${HUB_URL}/health/ready" "the Hub"
}

step "Start daemons A and B, the two-pod proxy and the Hub"
start_a
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/b.toml" >> "${TMP_DIR}/b.log" 2>&1 &
PIDS+=($!); disown "$!" 2>/dev/null || true
wait_http "http://127.0.0.1:${B_HTTP}/api/status" "daemon B"
python3 "${TMP_DIR}/proxy.py" "${PROXY_PORT}" "http://127.0.0.1:${A_HTTP}" "http://127.0.0.1:${B_HTTP}" &
PIDS+=($!); disown "$!" 2>/dev/null || true
start_hub
HUB_VERSION="$(curl -fsS "${HUB_URL}/api/status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version", "?"))')"
ok "Hub ${HUB_VERSION} on ${HUB_URL}, polling every 2 s"

# --- load ----------------------------------------------------------------------
cat > "${TMP_DIR}/build_payload.py" <<'PY'
import sys, time
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

out, count, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
now = time.time_ns()

def kv(k, v):
    return common.KeyValue(key=k, value=common.AnyValue(string_value=v))

def n1_trace(tid):
    # One HTTP root and six SELECTs differing only by id: one n_plus_one_sql.
    trace_id = tid.to_bytes(16, "big")
    root = (1).to_bytes(8, "big")
    spans = [trace.Span(trace_id=trace_id, span_id=root, name="GET /api/orders",
                        kind=trace.Span.SPAN_KIND_SERVER,
                        start_time_unix_nano=now, end_time_unix_nano=now + 50_000_000,
                        attributes=[kv("http.route", "/api/orders")])]
    for i in range(6):
        start = now + (i + 1) * 1_000_000
        spans.append(trace.Span(
            trace_id=trace_id, span_id=(i + 2).to_bytes(8, "big"), parent_span_id=root,
            name="SELECT", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=start, end_time_unix_nano=start + 500_000,
            attributes=[kv("db.system", "postgresql"),
                        kv("db.statement", "SELECT * FROM orders WHERE id = %d" % (i + 1))]))
    return spans

rs = trace.ResourceSpans(
    resource=resource.Resource(attributes=[kv("service.name", "hdv-planted")]),
    scope_spans=[trace.ScopeSpans(spans=[s for t in range(count) for s in n1_trace(base + t)])])
open(out, "wb").write(svc.ExportTraceServiceRequest(resource_spans=[rs]).SerializeToString())
PY
post() {  # $1 = daemon http port, $2 = payload
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "http://127.0.0.1:$1/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"$2")"
  [ "${code}" = "200" ] || die "OTLP POST to :$1 answered ${code}"
}
daemon_planted() {  # $1 = daemon http port; prints "<ledger_id> <planted count> <signature>"
  curl -fsS "http://127.0.0.1:$1/api/detections?limit=5000" | python3 -c '
import json, sys
p = json.load(sys.stdin)
rows = [r for r in p["counts"] if r["signature"].startswith("n_plus_one_sql:hdv-planted:")]
print(p["ledger_id"], sum(r["detections"] for r in rows), rows[0]["signature"] if rows else "-")'
}

TODAY_MS="$(python3 -c 'import time; print(int(time.time() * 1000) // 86400000 * 86400000)')"
# Prints one JSON summary of the windowed read: the finding's fields and each source's.
hub_volume() {
  python3 - "${HUB_URL}" "${SIG}" "${TODAY_MS}" <<'PY'
import json, sys, time, urllib.parse, urllib.request
url, sig, frm = sys.argv[1], sys.argv[2], sys.argv[3]
q = urllib.parse.urlencode({"signature": sig, "from": frm, "to": int(time.time() * 1000)})
try:
    rows = json.load(urllib.request.urlopen(url + "/api/findings?" + q, timeout=10))
except Exception as e:  # a failed read is retried by the caller, never fatal here
    print(json.dumps({"listed": False, "error": str(e)})); sys.exit()
if not rows:
    print(json.dumps({"listed": False})); sys.exit()
f = rows[0]
pick = lambda o: {k: o.get(k, "absent") for k in ("detections", "detections_complete", "detections_gaps")}
print(json.dumps({"listed": True, "finding": pick(f), "sources": {s["id"]: pick(s) for s in f.get("sources", [])}}))
PY
}
field() {  # $1 = summary json, $2 = python expression over s
  python3 -c "import json,sys; s=json.loads(sys.argv[1]); print($2)" "$1"
}

step "Post ${K1} planted N+1 traces to daemon A and to daemon B"
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/k1.pb" "${K1}" 1000
post "${A_HTTP}" "${TMP_DIR}/k1.pb"
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/k1b.pb" "${K1}" 2000
post "${B_HTTP}" "${TMP_DIR}/k1b.pb"
A_LEDGER_1="-"; A_COUNT=0; SIG="-"
for _ in $(seq 1 40); do
  read -r A_LEDGER_1 A_COUNT SIG <<< "$(daemon_planted "${A_HTTP}")"
  [ "${A_COUNT}" = "${K1}" ] && break
  sleep 0.5
done
[ "${A_COUNT}" = "${K1}" ] || die "daemon A counts ${A_COUNT} planted detections, want ${K1}"
read -r _ B_COUNT B_SIG <<< "$(daemon_planted "${B_HTTP}")"
[ "${B_SIG}" = "${SIG}" ] || die "daemons A and B disagree on the signature: ${SIG} vs ${B_SIG}"
ok "both daemons count ${K1}, signature ${SIG}"

step "H1 the same total through poll (hdv-poll) and push (hdv-push)"
# The daemon pushes its ledger at most once a minute.
SUMMARY=""
for _ in $(seq 1 75); do
  SUMMARY="$(hub_volume)"
  if [ "$(field "${SUMMARY}" 's["listed"]')" = "True" ]; then
    [ "$(field "${SUMMARY}" 's["finding"]["detections"]')" = "absent" ] \
      && die "H1 the windowed read carries no detections field: Hub ${HUB_VERSION} serves no detection volume (0.8.6 and later)"
    [ "$(field "${SUMMARY}" 's["sources"].get("hdv-poll", {}).get("detections")')" = "${K1}" ] \
      && [ "$(field "${SUMMARY}" 's["sources"].get("hdv-push", {}).get("detections")')" = "${K1}" ] && break
  fi
  sleep 2
done
POLL_1="$(field "${SUMMARY}" 's["sources"].get("hdv-poll", {}).get("detections")')"
PUSH_1="$(field "${SUMMARY}" 's["sources"].get("hdv-push", {}).get("detections")')"
[ "${POLL_1}" = "${K1}" ] && [ "${PUSH_1}" = "${K1}" ] \
  || die "H1 hdv-poll serves ${POLL_1}, hdv-push ${PUSH_1}, want ${K1} each (last read: ${SUMMARY})"
ok "hdv-poll ${POLL_1} by poll, hdv-push ${PUSH_1} by push"

step "H2 daemon A restarts and takes ${K2} more: the Hub adds the two ledgers"
stop_a
start_a
python3 "${TMP_DIR}/build_payload.py" "${TMP_DIR}/k2.pb" "${K2}" 3000
post "${A_HTTP}" "${TMP_DIR}/k2.pb"
WANT=$((K1 + K2))
POLL_2=""
for _ in $(seq 1 40); do
  SUMMARY="$(hub_volume)"
  POLL_2="$(field "${SUMMARY}" 's["sources"].get("hdv-poll", {}).get("detections")')"
  [ "${POLL_2}" = "${WANT}" ] && break
  sleep 1
done
read -r A_LEDGER_2 A_COUNT_2 _ <<< "$(daemon_planted "${A_HTTP}")"
[ "${A_LEDGER_2}" != "${A_LEDGER_1}" ] || die "H2 daemon A kept ledger ${A_LEDGER_1} across the restart"
[ "${A_COUNT_2}" = "${K2}" ] || die "H2 daemon A's new ledger counts ${A_COUNT_2}, want ${K2}"
[ "${POLL_2}" = "${WANT}" ] || die "H2 hdv-poll serves ${POLL_2}, want ${K1} + ${K2} = ${WANT} (last read: ${SUMMARY})"
POLL_GAPS="$(field "${SUMMARY}" '",".join(s["sources"]["hdv-poll"]["detections_gaps"])')"
POLL_COMPLETE="$(field "${SUMMARY}" 's["sources"]["hdv-poll"]["detections_complete"]')"
case ",${POLL_GAPS}," in *,restart,*) ;; *) die "H2 hdv-poll gaps [${POLL_GAPS}] lack restart" ;; esac
case ",${POLL_GAPS}," in *,multi_instance,*) die "H2 two successive ledgers read as multi_instance: [${POLL_GAPS}]" ;; esac
[ "${POLL_COMPLETE}" = "False" ] || die "H2 hdv-poll complete=${POLL_COMPLETE}, want false"
ok "daemon A: ledger ${A_LEDGER_1} -> ${A_LEDGER_2} counting ${A_COUNT_2}, Hub: ${POLL_2}, gaps [${POLL_GAPS}]"

step "H3 two pods behind one address read as multi_instance"
PODS_GAPS=""
for _ in $(seq 1 30); do
  SUMMARY="$(hub_volume)"
  PODS_GAPS="$(field "${SUMMARY}" '",".join(s["sources"].get("hdv-pods", {}).get("detections_gaps", []))')"
  case ",${PODS_GAPS}," in *,multi_instance,*) break ;; esac
  sleep 1
done
case ",${PODS_GAPS}," in *,multi_instance,*) ;; *) die "H3 hdv-pods gaps [${PODS_GAPS}] lack multi_instance (last read: ${SUMMARY})" ;; esac
PODS="$(field "${SUMMARY}" 's["sources"]["hdv-pods"]["detections"]')"
PUSH_GAPS="$(field "${SUMMARY}" '",".join(s["sources"]["hdv-push"]["detections_gaps"])')"
case ",${PUSH_GAPS}," in *,multi_instance,*) die "H3 the push-only source reads multi_instance: [${PUSH_GAPS}]" ;; esac
[ "${PODS}" != "None" ] || die "H3 hdv-pods serves a null count"
ok "hdv-pods ${PODS} detections, gaps [${PODS_GAPS}], hdv-push gaps [${PUSH_GAPS}]"

step "H4 the finding sums its sources and is incomplete"
H4="$(field "${SUMMARY}" '"%s %s %s" % (s["finding"]["detections"], sum(v["detections"] or 0 for v in s["sources"].values()), s["finding"]["detections_complete"])')"
read -r F_TOTAL F_SUM F_COMPLETE <<< "${H4}"
[ "${F_TOTAL}" = "${F_SUM}" ] || die "H4 the finding serves ${F_TOTAL}, its sources sum to ${F_SUM}"
[ "${F_COMPLETE}" = "False" ] || die "H4 the finding complete=${F_COMPLETE}, want false"
ok "finding ${F_TOTAL} = sum of sources, complete=false"

step "H5 a read without from or to is unchanged"
LEAKED="$(curl -fsS "${HUB_URL}/api/findings?signature=${SIG}" | python3 -c '
import json, sys
names = {"detections", "detections_complete", "avoidable_io_ops", "detections_gaps",
         "detections_sampling_rate", "detections_from", "detections_to"}
rows = json.load(sys.stdin)
assert rows, "the finding is not listed"
f = rows[0]
print(",".join(sorted((names & f.keys()) | {n for s in f["sources"] for n in names & s.keys()})) or "none")')" \
  || die "H5 unwindowed read failed"
[ "${LEAKED}" = "none" ] || die "H5 the unwindowed read carries ${LEAKED}"
ok "no detection field without a window"

step "H6 the poll passes reach /metrics"
READS_OK="$(curl -fsS "${HUB_URL}/metrics" | awk '/^perf_sentinel_hub_detection_reads_total\{.*source="hdv-poll".*outcome="ok"/ {print $NF}')"
[ -n "${READS_OK}" ] && [ "${READS_OK%.*}" -gt 0 ] || die "H6 detection_reads_total{source=\"hdv-poll\",outcome=\"ok\"} is '${READS_OK}'"
ok "hdv-poll: ${READS_OK} passes ended ok"

{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Daemons: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo "- Hub: ${HUB_DLL} (${HUB_VERSION})"
  echo ""
  echo "| id | check | result |"
  echo "|---|---|---|"
  echo "| H1 | same load by poll and by push | hdv-poll ${POLL_1}, hdv-push ${PUSH_1}, want ${K1} |"
  echo "| H2 | restart of daemon A | daemon ledger ${A_COUNT_2}, Hub ${POLL_2} = ${K1} + ${K2}, gaps [${POLL_GAPS}] |"
  echo "| H3 | two pods behind one address | hdv-pods gaps [${PODS_GAPS}], hdv-push gaps [${PUSH_GAPS}] |"
  echo "| H4 | finding level | ${F_TOTAL} = sum of sources, complete=false |"
  echo "| H5 | unwindowed read | no detection field |"
  echo "| H6 | /metrics | ${READS_OK} ok passes for hdv-poll |"
  echo ""
  echo "Verdict: **PASS**"
} > "${REPORT}"
color_green "PASS, report at ${REPORT}"
