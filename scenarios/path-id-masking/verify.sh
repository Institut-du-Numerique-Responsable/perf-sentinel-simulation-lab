#!/usr/bin/env bash
# path-id-masking: validate the product 0.44.0 path id masking on the batch
# path (no cluster, no daemon, local release binary).
#
#   P  URL path templates   an upper-case code and a hex id become {id}, so
#                           six dossiers read one by one are an N+1. Fixed
#                           words with a number (H264, H265) and an RPC
#                           service name (WAFV2) keep their segment
#   E  source.endpoint      a SERVER url.path with no http.route is masked,
#                           over OTLP, Jaeger and Zipkin. Two http.route
#                           templates that differ by a version digit stay
#                           two endpoints
#   D  report --before      a baseline written by 0.43.2 (raw endpoints)
#                           compares clean against the masked run
#   K  acknowledgment       an entry written on a raw path names the masked
#                           signature to acknowledge again
#   W  daemon               a loopback `watch` fed the same spans over
#                           OTLP/protobuf serves the masked endpoint on
#                           /api/findings and counts both dossiers on one
#                           /api/detections row, the production symptom
#
# Against 0.43.2, P1, P2, E1, E1b, E3, E4, K1, K2, W1 and W2 fail, see README.md.
set -euo pipefail

SCENARIO="path-id-masking"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
rm -rf "${TMP_DIR}" && mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${PIM_DAEMON_HTTP_PORT:-14958}"
DAEMON_GRPC_PORT="${PIM_DAEMON_GRPC_PORT:-14957}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

DAEMON_PID=""
cleanup() { [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null; return 0; }
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v python3 >/dev/null || die "python3 not on PATH"
python3 -c 'import opentelemetry.proto' 2>/dev/null \
  || die "the daemon leg needs opentelemetry-proto: pip install opentelemetry-proto"
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
step "Pre-flight"
ok "binary perf-sentinel ${BIN_VERSION}"
for f in paths.ndjson endpoints.ndjson jaeger.json zipkin.json baseline-0.43.2.json; do
  [ -f "${FIX}/${f}" ] || die "fixture missing: ${FIX}/${f}"
done

analyze() {  # $1 = fixture, $2 = output name, then extra flags
  local fixture="$1" out="$2"; shift 2
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/${fixture}" --format json "$@" \
    > "${TMP_DIR}/${out}.json" 2> "${TMP_DIR}/${out}.err" \
    || die "analyze failed on ${fixture}: $(tail -2 "${TMP_DIR}/${out}.err")"
}

step "analyze the fixtures"
for f in paths endpoints; do analyze "${f}.ndjson" "${f}" --no-acknowledgments; done
for f in jaeger zipkin; do analyze "${f}.json" "${f}" --no-acknowledgments; done
ok "four reports"

step "report --before the 0.43.2 baseline"
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${FIX}/endpoints.ndjson" --no-acknowledgments \
  --before "${FIX}/baseline-0.43.2.json" --output "${TMP_DIR}/report.html" \
  2> "${TMP_DIR}/report.err" || die "report failed: $(tail -2 "${TMP_DIR}/report.err")"
ok "report.html"

step "acknowledgment written on the 0.43.2 raw path"
ACK_SIG="$(python3 -c "
import json
d = json.load(open('${FIX}/baseline-0.43.2.json'))
print([f['signature'] for f in d['findings'] if f['source_endpoint'] == '/api/dossiers/K7QX2P'][0])")"
cat > "${TMP_DIR}/ack.toml" <<TOML
[[acknowledged]]
signature = "${ACK_SIG}"
acknowledged_by = "lab@example.com"
acknowledged_at = "2026-11-10"
reason = "dossier lines read one by one, batching scheduled"
service = "crm-svc"
source_endpoint = "/api/dossiers/K7QX2P"
TOML
analyze endpoints.ndjson acked --acknowledgments "${TMP_DIR}/ack.toml"
ok "ack on ${ACK_SIG}"

step "daemon: the same spans over OTLP/protobuf"
if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
  die "port ${DAEMON_HTTP_PORT} already answers, stop that daemon or set PIM_DAEMON_HTTP_PORT"
fi
cat > "${TMP_DIR}/daemon.toml" <<TOML
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
TOML
# The fixture's OTLP/JSON documents, shifted to the current time so the
# ledger counts them today, merged into one protobuf export.
python3 - "${FIX}/endpoints.ndjson" "${TMP_DIR}/endpoints.pb" <<'PY'
import json, sys, time
from google.protobuf import json_format
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc

src, out = sys.argv[1], sys.argv[2]
docs = [json.loads(line) for line in open(src) if line.strip()]
starts = [int(s["startTimeUnixNano"]) for d in docs for rs in d["resourceSpans"]
          for ss in rs["scopeSpans"] for s in ss["spans"]]
shift = time.time_ns() - min(starts)
merged = svc.ExportTraceServiceRequest()
for d in docs:
    for rs in d["resourceSpans"]:
        for ss in rs["scopeSpans"]:
            for s in ss["spans"]:
                for key in ("startTimeUnixNano", "endTimeUnixNano"):
                    s[key] = str(int(s[key]) + shift)
    part = json_format.ParseDict(d, svc.ExportTraceServiceRequest())
    merged.resource_spans.extend(part.resource_spans)
open(out, "wb").write(merged.SerializeToString())
PY
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 40); do
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
  || die "daemon not ready on ${DAEMON_URL}: $(tail -3 "${TMP_DIR}/daemon.log")"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
  -H 'Content-Type: application/x-protobuf' --data-binary @"${TMP_DIR}/endpoints.pb")"
[ "${CODE}" = "200" ] || die "OTLP POST answered ${CODE}"
# Four traces, four N+1 detections once the 1 s TTL evicts them.
for _ in $(seq 1 40); do
  curl -fsS --max-time 10 "${DAEMON_URL}/api/detections?limit=5000" > "${TMP_DIR}/detections.json" \
    || die "GET /api/detections failed"
  python3 -c "
import json, sys
rows = json.load(open(sys.argv[1]))['counts']
sys.exit(0 if sum(r['detections'] for r in rows) >= 4 else 1)" "${TMP_DIR}/detections.json" && break
  sleep 0.5
done
sleep 2  # a late batch must not move the counts
curl -fsS --max-time 10 "${DAEMON_URL}/api/detections?limit=5000" > "${TMP_DIR}/detections.json"
curl -fsS --max-time 10 "${DAEMON_URL}/api/findings?limit=1000" > "${TMP_DIR}/findings.json" \
  || die "GET /api/findings failed"
kill -TERM "${DAEMON_PID}" 2>/dev/null || true
wait "${DAEMON_PID}" 2>/dev/null || true
DAEMON_PID=""
ok "daemon answered, ledger and findings read"

step "Assertions"
set +e
python3 - "${TMP_DIR}" "${FIX}/baseline-0.43.2.json" "${REPORT}" "${BIN_VERSION}" <<'PY'
import json
import re
import sys

tmp, baseline_path, report_path, version = sys.argv[1:5]
load = lambda name: json.load(open(f"{tmp}/{name}.json"))
paths, endpoints = load("paths"), load("endpoints")
jaeger, zipkin, acked = load("jaeger"), load("zipkin"), load("acked")
baseline = json.load(open(baseline_path))
rows, failures = [], 0


def check(tid, desc, actual, expected):
    global failures
    passed = actual == expected
    failures += not passed
    rows.append((tid, passed, desc, actual, expected))
    mark = "\033[32m    ok\033[0m" if passed else "\033[31m  FAIL\033[0m"
    detail = f"{actual!r}" if passed else f"got {actual!r}, want {expected!r}"
    print(f"{mark}  {tid:4s} {desc}: {detail}")


def templates(report, service, kind):
    return sorted(f["pattern"]["template"] for f in report["findings"]
                  if f["service"] == service and f["type"] == kind)


def endpoint_list(report, service):
    return sorted(f["source_endpoint"] for f in report["findings"]
                  if f["service"] == service and f["type"] == "n_plus_one_sql")


# --- P. URL path templates ----------------------------------------------------
check("P1", "six dossier codes read one by one are one N+1",
      templates(paths, "paths-codes", "n_plus_one_http"),
      ["GET crm-api/api/dossiers/{id}"])
check("P2", "six Mongo ObjectIds read one by one are one N+1",
      templates(paths, "paths-hex", "n_plus_one_http"),
      ["GET catalog-api/api/items/{id}"])
check("P3", "H264 and H265 stay two redundant calls, not one {id}",
      templates(paths, "paths-fixed", "redundant_http"),
      ["GET media-api/api/codec/H264", "GET media-api/api/codec/H265"])
check("P4", "the RPC service name WAFV2 is not a code",
      templates(paths, "paths-rpc", "redundant_http"),
      ["aws-api WAFV2/ListWebACLs"])

# --- E. source.endpoint -------------------------------------------------------
crm = [f for f in endpoints["findings"] if f["service"] == "crm-svc"]
check("E1", "a SERVER url.path without http.route is masked (OTLP)",
      endpoint_list(endpoints, "crm-svc"), ["/api/dossiers/{id}"] * 2)
check("E1b", "the two dossiers share one signature",
      len({f["signature"] for f in crm}), 1)
check("E2", "two http.route versions stay two endpoints",
      endpoint_list(endpoints, "jira-svc"),
      ["/rest/api/2/issue/{key}", "/rest/api/3/issue/{key}"])
check("E3", "a Jaeger http.target is masked",
      endpoint_list(jaeger, "jaeger-svc"), ["/api/orders/{id}"])
check("E4", "a Zipkin http.target is masked",
      endpoint_list(zipkin, "zipkin-svc"), ["/api/orders/{id}"])

# --- D. report --before an older baseline -------------------------------------
html = open(f"{tmp}/report.html").read()
payload = json.loads(re.search(
    r'<script id="report-data" type="application/json">(.*?)</script>', html, re.S).group(1))
diff = payload.get("diff") or {}
check("D0", "the baseline really holds raw endpoints",
      sorted(f["source_endpoint"] for f in baseline["findings"] if f["service"] == "crm-svc"),
      ["/api/dossiers/K7QX2P", "/api/dossiers/R4TN8W"])
check("D1", "no new finding against the 0.43.2 baseline",
      len(diff.get("new_findings", [None])), 0)
check("D2", "no resolved finding against the 0.43.2 baseline",
      len(diff.get("resolved_findings", [None])), 0)
check("D3", "no endpoint delta against the 0.43.2 baseline",
      len(diff.get("endpoint_metric_deltas", [None])), 0)

# --- W. daemon ----------------------------------------------------------------
ledger = json.load(open(f"{tmp}/detections.json"))["counts"]
served = json.load(open(f"{tmp}/findings.json"))
served = served if isinstance(served, list) else served.get("findings", [])
served = [it.get("finding", it) for it in served]
check("W1", "/api/findings serves the masked endpoint",
      sorted({f["source_endpoint"] for f in served if f["service"] == "crm-svc"}),
      ["/api/dossiers/{id}"])
check("W2", "/api/detections counts both dossiers on one row",
      sorted(r["detections"] for r in ledger
             if r["signature"].startswith("n_plus_one_sql:crm-svc:")), [2])
check("W3", "the two http.route versions keep two rows",
      sorted(r["detections"] for r in ledger
             if r["signature"].startswith("n_plus_one_sql:jira-svc:")), [1, 1])

# --- K. acknowledgment on a raw path ------------------------------------------
warnings = [w["message"] for w in acked.get("warning_details") or []
            if w.get("kind") == "unmatched_acknowledgment"]
successor = crm[0]["signature"] if crm else ""
check("K1", "the warning names the masked signature to acknowledge again",
      bool(warnings) and successor in warnings[0] and "re-acknowledge" in warnings[0], True)
check("K2", "the finding still fires, the ack does not carry over",
      len([f for f in acked["findings"] if f["service"] == "crm-svc"]), 2)

with open(report_path, "w") as fh:
    fh.write(f"# path-id-masking (perf-sentinel {version})\n\n")
    fh.write("| id | result | assertion | actual | expected |\n|---|---|---|---|---|\n")
    for tid, passed, desc, actual, expected in rows:
        fh.write(f"| {tid} | {'PASS' if passed else 'FAIL'} | {desc} | `{actual}` | `{expected}` |\n")
print(f"{len(rows) - failures}/{len(rows)} assertions passed")
sys.exit(1 if failures else 0)
PY
status=$?
set -e
if [ "${status}" -eq 0 ]; then
  color_green "PASS — report at ${REPORT}"
else
  color_red "FAIL — report at ${REPORT}"
  exit 1
fi
