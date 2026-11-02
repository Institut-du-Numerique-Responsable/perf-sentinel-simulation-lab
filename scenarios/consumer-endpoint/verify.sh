#!/usr/bin/env bash
# consumer-endpoint: a finding whose only same-service ancestor is a message
# CONSUMER span names its destination on the daemon path (product 0.22.2).
#
# notification-service consumes perfsim.order-service under the OTel javaagent
# and runs one N+1 SQL per message. The n-plus-one-messaging k6 job publishes
# from order-service, whose PRODUCER span becomes the consumer's parent through
# the propagated AMQP headers, so on the consumer side the CONSUMER span is the
# outermost same-service ancestor and there is no route to prefer. The agent's
# spring-rabbit instrumentation writes the received routing key to
# messaging.destination.name, hence "rabbitmq order-service". On 0.22.1 the same
# finding reports "unknown".
#
# Prerequisites: a cluster (make up-cni, make seed-services with the listener,
# make seed-daemon-local at the branch), scripts/port-forward.sh start.
set -euo pipefail

SCENARIO="consumer-endpoint"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPECTED_ENDPOINT="${EXPECTED_ENDPOINT:-rabbitmq order-service}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

# run_scenario, RESULTS, DAEMON_URL, NAMESPACE. main() is guarded, so nothing runs.
# shellcheck source=../../scripts/validate-findings.sh
. "${REPO_ROOT}/scripts/validate-findings.sh"
# After the source: validate-findings.sh sets its own REPORT.
REPORT="/tmp/scenario-${SCENARIO}-report.md"

step "Pre-flight"
curl -fsS --max-time 10 "${DAEMON_URL}/api/status" >/dev/null \
  || die "daemon not reachable at ${DAEMON_URL}, run scripts/port-forward.sh start"
# Not grep -q: it stops at the first match, kubectl then dies on SIGPIPE and
# pipefail fails the check once the log outgrows the pipe buffer.
kubectl -n "${NAMESPACE}" logs deployment/notification-service --tail=5000 \
  | grep "Attempting to connect to: \[rabbitmq" >/dev/null \
  || die "notification-service runs no RabbitMQ listener, rebuild it with make seed-services"
ok "daemon reachable, consumer connected"

step "Drive n-plus-one-messaging, wait for a fresh consumer-rooted n_plus_one_sql"
STARTED_AT_MS="$(python3 -c 'import time; print(time.time_ns() // 1_000_000)')"
run_scenario "${SCENARIO}" "n_plus_one_sql" "notification-service" \
  "scenarios/n-plus-one-messaging.js" "${EXPECTED_ENDPOINT}"
IFS='|' read -r STATUS _ _ _ COUNT NOTE <<<"${RESULTS[0]}"
[ -z "${NOTE}" ] || color_red "    ${NOTE}"

step "Assertions on GET /api/findings"
FINDINGS="/tmp/${SCENARIO}-findings.json"
curl -fsS --max-time 10 "${DAEMON_URL}/api/findings?limit=10000&include_acked=true" > "${FINDINGS}"
set +e
python3 - "${FINDINGS}" "${STARTED_AT_MS}" "${EXPECTED_ENDPOINT}" "${STATUS}" "${COUNT}" "${REPORT}" <<'PY'
import json
import sys

path, started_at_ms, expected, status, count, report_path = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6])
fresh, folded = [], []
for item in json.load(open(path)):
    finding = item.get("finding", item)
    if (item.get("stored_at_ms", 0) > started_at_ms
            and finding.get("type") == "n_plus_one_sql"
            and finding.get("service") == "notification-service"):
        fresh.append(finding)
        folded.append(item.get("seen_count", 1))
by_endpoint = {}
for f in fresh:
    by_endpoint.setdefault(f["source_endpoint"], []).append(f)
rows, failures = [], 0


def check(tid, desc, actual, expected):
    global failures
    passed = actual == expected
    if not passed:
        failures += 1
    rows.append((tid, passed, desc, actual, expected))
    mark = "\033[32m    ok\033[0m" if passed else "\033[31m  FAIL\033[0m"
    detail = f"{actual!r}" if passed else f"got {actual!r}, want {expected!r}"
    print(f"{mark}  {tid:3s} {desc}: {detail}")


check("C1", "a fresh n_plus_one_sql on notification-service names the destination",
      status == "PASS" and count >= 1, True)
# The set of endpoints seen on the fresh consumer findings. "unknown" here is
# the 0.22.1 failure mode, another spelling means the agent moved the
# destination attribute (see README, discovering the spelling).
check("C2", "every fresh consumer finding carries the same destination",
      sorted(by_endpoint), [expected])
check("C3", "each finding carries at least the 12 reads of one message",
      bool(fresh) and min(f["pattern"]["occurrences"] for f in fresh) >= 12, True)
# /api/findings folds by signature, one row per problem: the traces behind the
# row are its seen_count, not distinct trace ids.
check("C4", "the row folds several fresh traces",
      bool(folded) and max(folded) >= 2, True)

with open(report_path, "w", encoding="utf-8") as fh:
    fh.write("# Scenario report: consumer-endpoint\n\n")
    fh.write(f"Fresh notification-service n_plus_one_sql findings by endpoint: "
             f"{ {k: len(v) for k, v in by_endpoint.items()} }\n\n")
    fh.write("| id | result | assertion | detail |\n|---|---|---|---|\n")
    for tid, passed, desc, actual, expected in rows:
        detail = f"`{actual}`" if passed else f"got `{actual}`, want `{expected}`"
        fh.write(f"| {tid} | {'PASS' if passed else 'FAIL'} | {desc} | {detail} |\n")
    fh.write(f"\n{len(rows) - failures}/{len(rows)} assertions passed.\n")
print(f"\n{len(rows) - failures}/{len(rows)} assertions passed")
sys.exit(1 if failures else 0)
PY
RC=$?
set -e

echo
if [ "${RC}" -eq 0 ]; then color_green "PASS - report at ${REPORT}"; else color_red "FAIL - report at ${REPORT}"; fi
exit "${RC}"
