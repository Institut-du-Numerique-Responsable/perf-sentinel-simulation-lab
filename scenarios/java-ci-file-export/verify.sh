#!/usr/bin/env bash
# java-ci-file-export: the Java agent in a forked Failsafe JVM writes OTLP JSON
# Lines straight to a file, with no `perf-sentinel capture`, no receiver and no
# port, and perf-sentinel analyzes that file.
#
# What made it possible: OpenTelemetry Java SDK 1.66.0 (open-telemetry/
# opentelemetry-java #8676) wires `output_stream: file:///...` into the
# `otlp_file/development` exporter. Declarative configuration only
# (OTEL_CONFIG_FILE): there is still no OTEL_* variable for it. The first agent
# bundling that SDK is 2.32.0. Not the
# OpenTelemetry Maven extension: that one traces the build itself (mojo spans,
# `not_io` to perf-sentinel) and still exports OTLP only.
#
# Uses the `otel-file` profile of the shared java-ci-capture fixture.
#
# Assertions (see README.md):
#   E1  mvn verify green with nothing listening on 4317/4318, the file is
#       non-empty OTLP JSON Lines, and its resource names the SDK that wrote
#       it (E6 is what proves the version matters).
#   E2  the fork is untouched: no Corrupted channel, no .dumpstream, no span on
#       Maven's stdout.
#   E3  analyze --ci on the file: every span of the request (ITEMS JDBC + 1
#       SERVER) and n_plus_one_sql at ITEMS occurrences.
#   E4  a re-run without `clean` APPENDS: the file doubles and the finding is
#       reported twice. The pipeline has to start from an empty file.
#   E5  a failing test: Maven exits non-zero and the file of the red run is
#       still complete and analyzable.
#   E6  negative control, the same profile on agent 2.31.1 (SDK 1.65): the
#       build stays GREEN, no file appears, and the spans are diverted to the
#       fork's stdout (Corrupted channel + .dumpstream). A silent zero.
#
# Self-contained: no cluster. Needs the local release binary, a JDK, Maven,
# Docker (throwaway PostgreSQL) and network access to Maven Central.
set -uo pipefail

SCENARIO="java-ci-file-export"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="${SCRIPT_DIR}/../java-ci-capture/fixtures"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18-alpine}"
PG_CONTAINER="jcfe-postgres"
PG_PORT="${PG_PORT:-15443}"
# The last agent without SDK 1.66, for the E6 control.
OLD_AGENT="${OLD_AGENT:-2.31.1}"
ITEMS="${ITEMS:-15}"
PROJECT="${TMP_DIR}/project"
TRACES="${PROJECT}/target/traces.jsonl"
REPORTS="${PROJECT}/target/failsafe-reports"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }

cleanup() { docker rm -f "${PG_CONTAINER}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ── preflight ───────────────────────────────────────────────────────────────
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v java >/dev/null 2>&1 || die "no JDK on PATH"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || die "Docker unavailable — needed for the throwaway PostgreSQL"
if command -v mvn >/dev/null 2>&1; then
  MVN="mvn"
elif [ -x "${SCRIPT_DIR}/../../services/mvnw" ]; then
  MVN="${SCRIPT_DIR}/../../services/mvnw"
else
  die "no mvn on PATH and no services/mvnw wrapper"
fi
# E1 claims "no receiver". Something on these ports would not change the
# outcome (the config file overrides the OTLP variables), but it would make the
# claim unprovable, so refuse rather than pass on a weaker statement.
for p in 4317 4318; do
  lsof -ti "tcp:${p}" >/dev/null 2>&1 \
    && die "port ${p} is in use; E1 asserts the export needs no receiver at all"
done

step "Throwaway PostgreSQL on :${PG_PORT}"
docker rm -f "${PG_CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${PG_CONTAINER}" \
  -e POSTGRES_USER=lab -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=labdb \
  -p "${PG_PORT}:5432" "${POSTGRES_IMAGE}" >/dev/null || die "postgres start failed"
PG_READY=0
for _ in $(seq 1 60); do
  # A real query, not pg_isready: initdb's temporary server answers first.
  docker exec "${PG_CONTAINER}" psql -U lab -d labdb -Atqc 'SELECT 1' >/dev/null 2>&1 \
    && { PG_READY=1; break; }
  sleep 1
done
[ "${PG_READY}" = "1" ] || die "postgres never became ready: $(docker logs "${PG_CONTAINER}" 2>&1 | tail -3)"
docker exec "${PG_CONTAINER}" psql -U lab -d labdb -q -c \
  "CREATE TABLE lab_order_items (id serial PRIMARY KEY, order_id int NOT NULL);
   INSERT INTO lab_order_items (order_id) SELECT g % 20 FROM generate_series(1, 200) g;" \
  >/dev/null 2>&1 || die "seeding lab_order_items failed"
ok "lab_order_items seeded"

# Built in TMP_DIR so no target/ ever appears in the repository.
cp -R "${FIXTURES}" "${PROJECT}"
DB_URL="jdbc:postgresql://localhost:${PG_PORT}/labdb?user=lab&password=lab"

mvn_file() {  # the no-capture shape: just the test command, with the profile
  "${MVN}" -B -f "${PROJECT}/pom.xml" -P otel-file verify \
    "-Dlab.db.url=${DB_URL}" "-Dlab.items=${ITEMS}" "$@"
}

analyze_json() {  # $1 = input ; $2 = output ; --ci trips on findings, rc ignored
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --ci --input "$1" --format json \
    > "$2" 2> "${TMP_DIR}/analyze-err.txt"
}

span_count() {  # spans of the largest trace: the request, not the schema setup
  [ -s "$1" ] || { echo 0; return; }
  python3 -c '
import json, sys
from collections import Counter
traces = Counter()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    for rs in json.loads(line).get("resourceSpans", []):
        for ss in rs.get("scopeSpans", []):
            for sp in ss.get("spans", []):
                traces[sp.get("traceId", "")] += 1
print(max(traces.values()) if traces else 0)
' "$1"
}

occurrences() {  # "<findings of type> <max occurrences>" for $2 in $1
  [ -s "$1" ] || { echo "0 0"; return; }
  python3 -c '
import json, sys
occ = [f.get("pattern", {}).get("occurrences", 0)
       for f in json.load(open(sys.argv[1])).get("findings", []) if f["type"] == sys.argv[2]]
print(len(occ), max(occ) if occ else 0)
' "$1" "$2"
}

line_count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# ── E1 / E2 / E3: the no-capture run ────────────────────────────────────────
step "E1-E3: mvn -P otel-file verify, nothing listening, no wrapper"
mvn_file > "${TMP_DIR}/e1-mvn.log" 2>&1
E1_RC=$?
E1_LINES="$(line_count "${TRACES}")"
E1_NON_OTLP="$(grep -cv '^{"resourceSpans"' "${TRACES}" 2>/dev/null || true)"
E1_SDK="$( [ -s "${TRACES}" ] && grep -o '"telemetry.sdk.version","value":{"stringValue":"[^"]*"' "${TRACES}" \
  | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
E1_AGENT="$(grep -o 'opentelemetry-javaagent - version: [^ ]*' "${TMP_DIR}/e1-mvn.log" | head -1 | awk '{print $NF}')"
if [ "${E1_RC}" = "0" ] && [ "${E1_LINES}" -gt 0 ] && [ "${E1_NON_OTLP}" = "0" ] && [ -n "${E1_SDK}" ]; then
  assert_pass "E1" "green build, ${E1_LINES} OTLP JSON lines in target/traces.jsonl, agent ${E1_AGENT}, SDK ${E1_SDK}, no receiver"
else
  assert_fail "E1" "mvn rc=${E1_RC}, lines=${E1_LINES}, non-OTLP lines=${E1_NON_OTLP}, agent=${E1_AGENT:-?}, sdk=${E1_SDK:-none}: $(grep -E 'ERROR|WARN.*otel' "${TMP_DIR}/e1-mvn.log" | head -2)"
fi

CORRUPT=$(grep -rci "Corrupted channel\|Corrupted STDOUT" "${REPORTS}" "${TMP_DIR}/e1-mvn.log" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
DUMPSTREAMS=$(ls "${REPORTS}"/*.dumpstream 2>/dev/null | wc -l | tr -d ' ')
ON_STDOUT=$(grep -c 'resourceSpans' "${TMP_DIR}/e1-mvn.log")
TESTS_RUN="$(grep -ho "Tests run: [0-9]*, Failures: [0-9]*, Errors: [0-9]*" "${TMP_DIR}/e1-mvn.log" | tail -1)"
if [ "${CORRUPT}" = "0" ] && [ "${DUMPSTREAMS}" = "0" ] && [ "${ON_STDOUT}" = "0" ] && [ -n "${TESTS_RUN}" ]; then
  assert_pass "E2" "fork untouched (${TESTS_RUN}): no channel corruption, no .dumpstream, no span on stdout"
else
  assert_fail "E2" "corrupted=${CORRUPT}, dumpstreams=${DUMPSTREAMS}, span lines on stdout=${ON_STDOUT}, tests=[${TESTS_RUN:-none}]"
fi

EXPECTED_SPANS=$((ITEMS + 1))
cp "${TRACES}" "${TMP_DIR}/e1-traces.jsonl" 2>/dev/null || true
analyze_json "${TMP_DIR}/e1-traces.jsonl" "${TMP_DIR}/e3-findings.json"
E3_SPANS="$(span_count "${TMP_DIR}/e1-traces.jsonl")"
read -r E3_N E3_OCC <<< "$(occurrences "${TMP_DIR}/e3-findings.json" n_plus_one_sql)"
if [ "${E3_SPANS}" = "${EXPECTED_SPANS}" ] && [ "${E3_N}" = "1" ] && [ "${E3_OCC}" = "${ITEMS}" ]; then
  assert_pass "E3" "${E3_SPANS} spans = ${ITEMS} JDBC + 1 SERVER, n_plus_one_sql at ${E3_OCC} occurrences"
else
  assert_fail "E3" "spans=${E3_SPANS} (want ${EXPECTED_SPANS}), n_plus_one_sql findings=${E3_N} (want 1) at ${E3_OCC} occurrences (want ${ITEMS}): $(tail -2 "${TMP_DIR}/analyze-err.txt")"
fi

# ── E4: APPEND ──────────────────────────────────────────────────────────────
# The exporter opens the file CREATE+APPEND (the spec's "streaming appending").
# A persistent workspace (a Jenkins agent, a self-hosted runner) that runs the
# suite again without `clean` hands perf-sentinel both runs.
step "E4: a second run without clean appends to the same file"
mvn_file > "${TMP_DIR}/e4-mvn.log" 2>&1
E4_RC=$?
E4_LINES="$(line_count "${TRACES}")"
analyze_json "${TRACES}" "${TMP_DIR}/e4-findings.json"
read -r E4_N E4_OCC <<< "$(occurrences "${TMP_DIR}/e4-findings.json" n_plus_one_sql)"
if [ "${E4_RC}" = "0" ] && [ "${E4_LINES}" = "$((E1_LINES * 2))" ] && [ "${E4_N}" = "2" ]; then
  assert_pass "E4" "file appended (${E1_LINES} -> ${E4_LINES} lines), n_plus_one_sql reported ${E4_N} times: remove the file before the test step"
else
  assert_fail "E4" "mvn rc=${E4_RC}, lines ${E1_LINES} -> ${E4_LINES} (want $((E1_LINES * 2))), n_plus_one_sql findings=${E4_N} (want 2)"
fi

# ── E5: a red suite still leaves its file ───────────────────────────────────
step "E5: a failing test, file removed first"
rm -f "${TRACES}"
mvn_file -Dlab.fail=1 > "${TMP_DIR}/e5-mvn.log" 2>&1
E5_RC=$?
analyze_json "${TRACES}" "${TMP_DIR}/e5-findings.json"
E5_SPANS="$(span_count "${TRACES}")"
read -r E5_N E5_OCC <<< "$(occurrences "${TMP_DIR}/e5-findings.json" n_plus_one_sql)"
if [ "${E5_RC}" != "0" ] && grep -q "BUILD FAILURE" "${TMP_DIR}/e5-mvn.log" \
   && [ "${E5_SPANS}" = "${EXPECTED_SPANS}" ] && [ "${E5_OCC}" = "${ITEMS}" ]; then
  assert_pass "E5" "Maven exited ${E5_RC} on the failing test, its file still carries ${E5_SPANS} spans and the N+1 at ${E5_OCC}"
else
  assert_fail "E5" "mvn rc=${E5_RC} (want non-zero), spans=${E5_SPANS} (want ${EXPECTED_SPANS}), occurrences=${E5_OCC} (want ${ITEMS})"
fi

# ── E6: the same YAML on an agent without SDK 1.66 ──────────────────────────
# SDK 1.65 parses `output_stream` and ignores it: the exporter keeps its default
# stream, System.out, which in a forked Failsafe JVM is the command channel.
step "E6: negative control on agent ${OLD_AGENT}"
rm -rf "${REPORTS}" "${TRACES}"
mvn_file "-Dlab.otel.file.agent.version=${OLD_AGENT}" > "${TMP_DIR}/e6-mvn.log" 2>&1
E6_RC=$?
E6_AGENT="$(grep -o 'opentelemetry-javaagent - version: [^ ]*' "${TMP_DIR}/e6-mvn.log" | head -1 | awk '{print $NF}')"
E6_DUMP=$(ls "${REPORTS}"/*.dumpstream 2>/dev/null | wc -l | tr -d ' ')
E6_CORRUPT=$(grep -ci "Corrupted channel" "${TMP_DIR}/e6-mvn.log")
if [ "${E6_AGENT}" = "${OLD_AGENT}" ] && [ "${E6_RC}" = "0" ] && [ ! -e "${TRACES}" ] \
   && [ "${E6_DUMP}" -gt 0 ] && [ "${E6_CORRUPT}" -gt 0 ]; then
  assert_pass "E6" "agent ${E6_AGENT}: BUILD SUCCESS with no trace file, spans diverted to the fork channel (.dumpstream) — the pin must be >= 2.32"
else
  assert_fail "E6" "agent=${E6_AGENT:-?}, mvn rc=${E6_RC}, file present=$([ -e "${TRACES}" ] && echo yes || echo no), dumpstreams=${E6_DUMP}, corrupted=${E6_CORRUPT}"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "Java agent in a forked Failsafe JVM writing OTLP JSON Lines to a file"
  echo "(SDK 1.66 \`otlp_file/development\` + \`output_stream\`), analyzed by"
  echo "\`perf-sentinel analyze --ci\` with no \`capture\` in between."
  echo ""
  echo "| assertion | result |"
  echo "|---|---|"
  for row in "${SUMMARY[@]}"; do
    printf "| %s | %s |\n" "${row%%|*}" "${row#*|}"
  done
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
