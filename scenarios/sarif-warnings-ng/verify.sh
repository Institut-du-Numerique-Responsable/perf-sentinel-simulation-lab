#!/usr/bin/env bash
# SARIF read by the parser Jenkins Warnings NG actually runs.
#
# 0.35.0 made the SARIF output valid against the 2.1.0 schema, and every result
# carried one location, without physicalLocation when the finding had no usable
# code.filepath. Valid SARIF, but violations-lib (behind analysis-model's
# SarifAdapter, the Warnings NG "sarif" tool) throws a NullPointerException on
# such a location and rejects the whole file: one structural finding was enough
# to lose every issue. Schema validation (ci-shift-left) cannot catch that, only
# the consumer's own parser can.
#
#   W1  analyze --format sarif on the demo fixture yields results both with and
#       without a source file (otherwise the run proves nothing)
#   W2  SarifAdapter parses the file without exception, one issue per result
#   W3  every result with a source file comes back with that file and line
#
# Needs Docker only, no cluster. The parser runs in a Maven container that
# copies analysis-model and its dependencies into a named volume cache.
#
# Optional knobs:
#   PERF_SENTINEL_IMAGE / PERF_SENTINEL_VERSION   image under test (resolve-image.sh)
#   MAVEN_IMAGE                                   default maven:3.9.16-eclipse-temurin-21
#   ANALYSIS_MODEL_VERSION                        default 14.20.0 (violations-lib 3.0.2)

set -euo pipefail

SCENARIO="sarif-warnings-ng"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9.16-eclipse-temurin-21}"
ANALYSIS_MODEL_VERSION="${ANALYSIS_MODEL_VERSION:-14.20.0}"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
cp "${SCENARIO_DIR}/parser/pom.xml" "${SCENARIO_DIR}/parser/ParseSarif.java" "${TMP_DIR}/"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

W1="FAIL"; W2="FAIL"; W3="FAIL"
W1_NOTE=""; W2_NOTE=""; W3_NOTE=""

step "1. analyze --format sarif on the demo fixture (${IMAGE})"
docker run --rm -v "${SCENARIO_DIR}/fixtures:/fixtures:ro" "${IMAGE}" \
  analyze --input /fixtures/demo.json --format sarif \
  > "${TMP_DIR}/demo.sarif" 2> "${TMP_DIR}/analyze.log" \
  || die "analyze failed, see ${TMP_DIR}/analyze.log"

# Expected issues, one line per result: rule, file ("-" without a location,
# the name Warnings NG gives a file-less issue), line (0 without a region).
python3 - "${TMP_DIR}/demo.sarif" > "${TMP_DIR}/expected.tsv" <<'PY'
import json, sys
for run in json.load(open(sys.argv[1]))['runs']:
    for r in run.get('results', []):
        phys = (r.get('locations') or [{}])[0].get('physicalLocation')
        if phys is None:
            print(f"{r['ruleId']}\t-\t0")
        else:
            line = (phys.get('region') or {}).get('startLine', 0)
            print(f"{r['ruleId']}\t{phys['artifactLocation']['uri']}\t{line}")
PY
TOTAL=$(wc -l < "${TMP_DIR}/expected.tsv" | tr -d ' ')
LOCATED=$(awk -F'\t' '$2 != "-"' "${TMP_DIR}/expected.tsv" | wc -l | tr -d ' ')
UNLOCATED=$((TOTAL - LOCATED))
W1_NOTE="${TOTAL} results, ${LOCATED} with a source file, ${UNLOCATED} without"
if [ "${LOCATED}" -gt 0 ] && [ "${UNLOCATED}" -gt 0 ]; then
  W1="PASS"; ok "W1 ${W1_NOTE}"
else
  warn "W1 ${W1_NOTE}, the fixture no longer exercises both shapes"
fi

step "2. Warnings NG parser (analysis-model ${ANALYSIS_MODEL_VERSION})"
if docker run --rm -v "${TMP_DIR}:/w" -v perf-sentinel-lab-m2:/root/.m2 -w /w "${MAVEN_IMAGE}" \
     sh -c "mvn -q -B -Danalysis-model.version=${ANALYSIS_MODEL_VERSION} dependency:copy-dependencies \
            && ls target/dependency > deps.txt \
            && java -cp 'target/dependency/*' ParseSarif.java demo.sarif > parsed.tsv" \
     > "${TMP_DIR}/parser.log" 2>&1; then
  PARSED=$(wc -l < "${TMP_DIR}/parsed.tsv" | tr -d ' ')
  W2_NOTE="${PARSED}/${TOTAL} issues read"
  if [ "${PARSED}" -eq "${TOTAL}" ]; then
    W2="PASS"; ok "W2 ${W2_NOTE}"
  else
    warn "W2 ${W2_NOTE}"
  fi
else
  W2_NOTE="parser rejected the file: $(grep -m1 -o 'NullPointerException.*' "${TMP_DIR}/parser.log" || tail -1 "${TMP_DIR}/parser.log")"
  warn "W2 ${W2_NOTE}"
  : > "${TMP_DIR}/parsed.tsv"
fi
VIOLATIONS_LIB=$(grep -m1 -oE '^violations-lib-[0-9]+(\.[0-9]+)*' "${TMP_DIR}/deps.txt" 2>/dev/null || echo "violations-lib ?")

step "3. Located results keep their file and line"
if [ "${W2}" = "PASS" ] && diff <(awk -F'\t' '$2 != "-"' "${TMP_DIR}/expected.tsv" | sort) \
                               <(awk -F'\t' '$2 != "-"' "${TMP_DIR}/parsed.tsv" | sort) \
                               > "${TMP_DIR}/located.diff"; then
  W3="PASS"; W3_NOTE="${LOCATED} file:line pairs match"
  ok "W3 ${W3_NOTE}"
else
  W3_NOTE="mismatch or nothing parsed, see ${TMP_DIR}/located.diff"
  warn "W3 ${W3_NOTE}"
fi

verdict="PASS"
for v in "${W1}" "${W2}" "${W3}"; do [ "${v}" = "PASS" ] || verdict="FAIL"; done

{
  echo "# sarif-warnings-ng"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Image: ${IMAGE}"
  echo "Parser: analysis-model ${ANALYSIS_MODEL_VERSION} SarifAdapter, ${VIOLATIONS_LIB} (${MAVEN_IMAGE})"
  echo
  echo "| id | verdict | detail |"
  echo "|----|---------|--------|"
  echo "| W1 | ${W1} | ${W1_NOTE} |"
  echo "| W2 | ${W2} | ${W2_NOTE} |"
  echo "| W3 | ${W3} | ${W3_NOTE} |"
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
else
  die "FAIL, see ${REPORT}"
fi
