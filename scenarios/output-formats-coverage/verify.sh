#!/usr/bin/env bash
# Output formats coverage, diff mode, signature presence, ack cap loader.
#
# 4 sub-tests run against artefacts produced by the ci-shift-left
# scenario (baseline-report.json, regression-report.json, regression.json):
#
#   6.A. Coverage of the 4 supported formats (text/json/sarif/html).
#        - text/json/sarif via `analyze --format`,
#        - html via `report` (the HTML emitter is a separate subcommand
#          in 0.5.17, not a flag on analyze).
#        Asserts every output is non-empty and well-formed, that JSON
#        and SARIF agree on the finding count, and that every JSON
#        finding carries a non-empty `signature` (added in 0.5.17).
#        SARIF signature presence is logged but does NOT fail the
#        scenario: it was absent from the SARIF emitter until 0.9.0 closed
#        that gap, and the scenario reports which side it observes rather
#        than pinning either.
#        Markdown format is probed and expected to fail. The failure is
#        logged informationally (memory item 11).
#
#   6.B. Diff mode. Runs `perf-sentinel diff --before baseline --after
#        regression --format json` and asserts the output schema includes
#        `new_findings`, `resolved_findings`, `severity_changes`, and
#        `endpoint_metric_deltas`. Asserts new_findings count > 0 (the
#        regression introduced findings vs the baseline).
#
#   6.C. Cap loader. Generates a 17 MiB ack file (above the 16 MiB
#        cap from `crates/sentinel-core/src/acknowledgments.rs:30`) and
#        feeds it to analyze. Asserts analyze fails gracefully with a
#        clear error message about size, not a panic.
#
#   6.D. Quality gate clean. Sanity check that the gate accepts a clean
#        baseline (smoke test for the CLI plumbing).
#
#   6.E. Real Chrome renders the batch-warning banner only when warnings are
#        present, and the findings CSV exposes the grouping columns.
#
#   6.F. The text `Window:` line is in the local time zone (0.23.0), nine
#        hours later under TZ=JST-9 and TZ=Asia/Tokyo than under UTC, the
#        named zone resolving with no zoneinfo in the image, and the JSON
#        output is identical between zones (wall-clock duration_ms aside).

set -euo pipefail

SCENARIO="output-formats-coverage"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
CISL_DIR="/tmp/ci-shift-left"
CISL_CONFIG="${LAB_ROOT}/scenarios/ci-shift-left/.perf-sentinel.toml"

# The image under validation, resolved by scripts/resolve-image.sh:
# PERF_SENTINEL_IMAGE, then PERF_SENTINEL_VERSION, then the daemon manifest pin.
# This scenario is where that rule was first written, after it sat on a
# hardcoded 0.5.17 for several minor releases and kept reporting a SARIF gap the
# product had closed in 0.9.0. It is now shared by every image-based scenario.
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"

if [ "$(uname -s)" = "Linux" ]; then
  DOCKER_NET_FLAGS=(--network host)
else
  DOCKER_NET_FLAGS=(--add-host=host.docker.internal:host-gateway)
fi

step "0. Pre-flight"

command -v docker  >/dev/null || die "docker not on PATH"
command -v jq      >/dev/null || die "jq not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"

[ -f "${CISL_DIR}/regression-traces.json" ] \
  || die "${CISL_DIR}/regression-traces.json missing, run 'make verify-ci-shift-left' first"
[ -f "${CISL_DIR}/baseline-traces.json" ] \
  || die "${CISL_DIR}/baseline-traces.json missing, run 'make verify-ci-shift-left' first"
[ -f "${CISL_DIR}/regression.json" ] \
  || die "${CISL_DIR}/regression.json missing, run 'make verify-ci-shift-left' first"

docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
ok "image ${IMAGE} available, ci-shift-left artefacts present"

# Stage everything inside TMP_DIR so docker run mounts a single
# directory. macOS Docker Desktop fails when a single file path is
# bind-mounted inside an already-mounted directory ("mountpoint outside
# of rootfs"). Same pattern used by ci-shift-left.
#
# source.json   = full fixture traces (input to analyze)
# baseline.json = filtered fixture (clean baseline traces)
cp "${CISL_DIR}/regression-traces.json" "${TMP_DIR}/source.json"
cp "${CISL_DIR}/baseline-traces.json"   "${TMP_DIR}/baseline.json"
cp "${CISL_DIR}/regression.json"        "${TMP_DIR}/cisl-regression.json"
cp "${CISL_CONFIG}"                     "${TMP_DIR}/.perf-sentinel.toml"

step "6.A. Coverage of 4 supported formats + signature presence"

# analyze writes the chosen format to stdout (no --output flag), so
# every invocation redirects > to a file inside TMP_DIR.

# JSON
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze --input /workdir/source.json --format json \
  > "${TMP_DIR}/findings.json" 2> "${TMP_DIR}/analyze-json.log" \
  || die "analyze --format json failed, see ${TMP_DIR}/analyze-json.log"

# SARIF
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze --input /workdir/source.json --format sarif \
  > "${TMP_DIR}/findings.sarif" 2> "${TMP_DIR}/analyze-sarif.log" \
  || die "analyze --format sarif failed"

# Text (stdout)
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze --input /workdir/source.json --format text \
  > "${TMP_DIR}/findings.txt" 2> "${TMP_DIR}/analyze-text.log" \
  || warn "analyze --format text exited non-zero (gate may be tripping); see ${TMP_DIR}/findings.txt"

# HTML via separate `report` subcommand. `-u` matches the host UID so the
# container can write into the bind-mounted dir. Without it Linux Docker
# fails with EACCES (the image's USER 65534 cannot write to a host dir
# owned by the runner user). macOS Docker Desktop hides this via uid-squash.
docker run --rm "${DOCKER_NET_FLAGS[@]}" -u "$(id -u):$(id -g)" \
  -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  report --input /workdir/source.json --output /workdir/findings.html \
  > "${TMP_DIR}/report-html.log" 2>&1 \
  || die "report --output html failed, see ${TMP_DIR}/report-html.log"

cat > "${TMP_DIR}/warning.toml" <<'EOF'
[green]
enabled = true
[green.scaphandre]
endpoint = "http://127.0.0.1:1/metrics"
EOF
docker run --rm "${DOCKER_NET_FLAGS[@]}" -u "$(id -u):$(id -g)" \
  -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  report --input /workdir/source.json --config /workdir/warning.toml \
    --output /workdir/findings-warning.html \
  > "${TMP_DIR}/report-warning-html.log" 2>&1 \
  || die "warning report failed, see ${TMP_DIR}/report-warning-html.log"

BROWSER_CHECK="${LAB_ROOT}/scenarios/ci-e2e-common/browser-check.sh"
"${BROWSER_CHECK}" "${TMP_DIR}/findings.html" dom > "${TMP_DIR}/clean.dom"
"${BROWSER_CHECK}" "${TMP_DIR}/findings-warning.html" dom > "${TMP_DIR}/warning.dom"
"${BROWSER_CHECK}" "${TMP_DIR}/findings.html" findings > "${TMP_DIR}/findings.csv"
if ! grep -qi 'TUNING.*batch run' "${TMP_DIR}/clean.dom" \
   && grep -qi 'TUNING.*\[green\.scaphandre\].*batch run' "${TMP_DIR}/warning.dom"; then
  ASSERT_HTML_WARNINGS="PASS"
  ok "Chrome shows the warning banner only on the warned report"
else
  ASSERT_HTML_WARNINGS="FAIL"
  warn "warning banner presence/absence is wrong"
fi
if python3 - "${TMP_DIR}/findings.csv" <<'PY'
import csv, sys
header = next(csv.reader(open(sys.argv[1], newline="")))
assert header[2:6] == ["service", "grouping_key", "grouping_value", "grouping_all"], header
PY
then
  ASSERT_CSV_HEADERS="PASS"
  ok "findings CSV includes grouping_key, grouping_value and grouping_all"
else
  ASSERT_CSV_HEADERS="FAIL"
  warn "findings CSV grouping headers are missing or misplaced"
fi

# All 4 outputs non-empty
JSON_BYTES=$(wc -c < "${TMP_DIR}/findings.json")
SARIF_BYTES=$(wc -c < "${TMP_DIR}/findings.sarif")
TEXT_BYTES=$(wc -c < "${TMP_DIR}/findings.txt")
HTML_BYTES=$(wc -c < "${TMP_DIR}/findings.html")
ok "format sizes: json=${JSON_BYTES}B sarif=${SARIF_BYTES}B text=${TEXT_BYTES}B html=${HTML_BYTES}B"

if [ "${JSON_BYTES}" -gt 0 ] && [ "${SARIF_BYTES}" -gt 0 ] \
   && [ "${TEXT_BYTES}" -gt 0 ] && [ "${HTML_BYTES}" -gt 1024 ]; then
  ASSERT_FORMATS="PASS"
  ok "assertion 4 formats produce non-empty output PASS"
else
  ASSERT_FORMATS="FAIL"
  warn "one or more formats empty"
fi

# Coherence: JSON findings count == SARIF results count
JSON_COUNT=$(jq '.findings | length' "${TMP_DIR}/findings.json")
SARIF_COUNT=$(jq '.runs[0].results | length' "${TMP_DIR}/findings.sarif")
if [ "${JSON_COUNT}" = "${SARIF_COUNT}" ] && [ "${JSON_COUNT}" -gt 0 ]; then
  ASSERT_COHERENCE="PASS"
  ok "assertion JSON/SARIF agree on count PASS (${JSON_COUNT})"
else
  ASSERT_COHERENCE="FAIL"
  warn "JSON ${JSON_COUNT} vs SARIF ${SARIF_COUNT} disagreement"
fi

# Signature presence in JSON: every finding has non-empty signature
JSON_WITH_SIG=$(jq '[.findings[] | select(.signature != null and .signature != "")] | length' \
  "${TMP_DIR}/findings.json")
if [ "${JSON_WITH_SIG}" = "${JSON_COUNT}" ] && [ "${JSON_COUNT}" -gt 0 ]; then
  ASSERT_SIG_JSON="PASS"
  ok "assertion signature on every JSON finding PASS"
else
  ASSERT_SIG_JSON="FAIL"
  warn "JSON signature: ${JSON_WITH_SIG}/${JSON_COUNT} populated"
fi

# Signature presence in SARIF: probe properties.signature OR
# fingerprints["perfsentinel/v1"]. Logged informationally, NOT fail.
SARIF_WITH_SIG=$(jq '
  [.runs[0].results[] |
    (.properties.signature // .fingerprints["perfsentinel/v1"] // empty)
  ] | length
' "${TMP_DIR}/findings.sarif" 2>/dev/null || echo 0)

if [ "${SARIF_WITH_SIG}" -gt 0 ]; then
  SIG_SARIF_NOTE="present (${SARIF_WITH_SIG}/${SARIF_COUNT})"
  ok "SARIF signature ${SIG_SARIF_NOTE} - upstream may have closed memory item 10"
else
  SIG_SARIF_NOTE="absent (gap, memory item 10)"
  warn "SARIF signature absent in 0.5.17 (known gap, see memory item 10)"
fi

# Markdown format: expect failure with clear error.
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze --input /workdir/source.json --format markdown \
  > "${TMP_DIR}/markdown-stdout.log" 2> "${TMP_DIR}/markdown-stderr.log" \
  && MD_EXIT=0 || MD_EXIT=$?
if [ "${MD_EXIT}" -ne 0 ]; then
  MARKDOWN_NOTE="rejected as expected (exit ${MD_EXIT}, gap memory item 11)"
  ok "markdown format rejected as expected"
else
  MARKDOWN_NOTE="accepted (upstream may have shipped markdown support, close memory item 11)"
  ok "markdown format accepted - upstream may have closed memory item 11"
fi

step "6.B. Diff mode (--before baseline, --after regression)"

# `-u` for the same bind-mount-EACCES reason as the `report` invocation.
docker run --rm "${DOCKER_NET_FLAGS[@]}" -u "$(id -u):$(id -g)" \
  -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  diff \
  --before /workdir/baseline.json \
  --after /workdir/source.json \
  --format json \
  --output /workdir/diff.json \
  > "${TMP_DIR}/diff.log" 2>&1 \
  && DIFF_EXIT=0 || DIFF_EXIT=$?

if [ ! -s "${TMP_DIR}/diff.json" ]; then
  warn "diff produced no output (exit ${DIFF_EXIT}), see ${TMP_DIR}/diff.log"
  ASSERT_DIFF_SCHEMA="FAIL"
  ASSERT_DIFF_NEW="FAIL"
  NEW_FINDINGS=0
else
  # Validate schema: 4 expected fields present AND each is an array
  # (not null). Plain `has()` accepts null values which would mask a
  # regression that ships the keys but with broken types.
  if jq -e '
    (.new_findings           | type == "array") and
    (.resolved_findings      | type == "array") and
    (.severity_changes       | type == "array") and
    (.endpoint_metric_deltas | type == "array")
  ' "${TMP_DIR}/diff.json" >/dev/null; then
    ASSERT_DIFF_SCHEMA="PASS"
    ok "diff schema PASS (4 expected fields present, all arrays)"
  else
    ASSERT_DIFF_SCHEMA="FAIL"
    warn "diff JSON missing one of the 4 expected array fields, see ${TMP_DIR}/diff.json"
  fi

  NEW_FINDINGS=$(jq '.new_findings | length' "${TMP_DIR}/diff.json" 2>/dev/null || echo 0)
  if [ "${NEW_FINDINGS}" -gt 0 ]; then
    ASSERT_DIFF_NEW="PASS"
    ok "diff identified ${NEW_FINDINGS} new findings vs baseline"
  else
    ASSERT_DIFF_NEW="FAIL"
    warn "diff identified 0 new findings (regression introduced no new diff signals)"
  fi
fi

step "6.C. Ack file cap loader (>16 MiB rejected)"

# Generate ~17 MiB of valid-ish TOML.
{
  printf '# B1 6.C: oversized ack file (>16 MiB) to validate cap loader\n'
  for i in $(seq 1 100000); do
    cat <<EOF

[[acknowledged]]
signature = "test_type:test_service:test_endpoint:$(printf '%016x' "${i}")"
acknowledged_by = "test"
acknowledged_at = "2026-05-02"
reason = "padding-iter-${i}-$(printf '%0150d' "${i}")"
EOF
  done
} > "${TMP_DIR}/oversized-acks.toml"

if [ "$(uname -s)" = "Linux" ]; then
  ACTUAL_SIZE=$(stat -c%s "${TMP_DIR}/oversized-acks.toml")
else
  ACTUAL_SIZE=$(stat -f%z "${TMP_DIR}/oversized-acks.toml")
fi
ok "generated ack file: ${ACTUAL_SIZE} bytes"

if [ "${ACTUAL_SIZE}" -le 16777216 ]; then
  warn "ack file only ${ACTUAL_SIZE} bytes (<= 16 MiB), the test will not exercise the cap"
fi

docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze \
  --input /workdir/source.json \
  --acknowledgments /workdir/oversized-acks.toml \
  --format json \
  > "${TMP_DIR}/oversized-stdout.log" 2> "${TMP_DIR}/oversized-stderr.log" \
  && CAP_EXIT=0 || CAP_EXIT=$?

if [ "${CAP_EXIT}" -ne 0 ]; then
  ok "analyze rejected oversized ack file (exit ${CAP_EXIT})"
  if grep -qiE 'too large|cap|16.*MiB|MAX_ACKNOWLEDGMENTS|TooLarge|exceeds' \
     "${TMP_DIR}/oversized-stderr.log" "${TMP_DIR}/oversized-stdout.log"; then
    ASSERT_CAP="PASS"
    ok "assertion cap loader fail message clear PASS"
  else
    ASSERT_CAP="FAIL"
    warn "rejected but error message unclear, see ${TMP_DIR}/oversized-stderr.log"
  fi
else
  ASSERT_CAP="FAIL"
  warn "analyze accepted oversized ack file (cap loader broken)"
fi

step "6.D. Sanity: gate on clean baseline"

docker run --rm "${DOCKER_NET_FLAGS[@]}" \
  -v "${TMP_DIR}:/workdir" \
  "${IMAGE}" analyze \
  --input /workdir/baseline.json \
  --config /workdir/.perf-sentinel.toml \
  --ci \
  > "${TMP_DIR}/sanity-stdout.log" 2> "${TMP_DIR}/sanity.log" \
  && SANITY_EXIT=0 || SANITY_EXIT=$?

if [ "${SANITY_EXIT}" -eq 0 ]; then
  ASSERT_SANITY="PASS"
  ok "clean gate PASS (sanity)"
else
  ASSERT_SANITY="WARN"
  warn "clean gate failed exit ${SANITY_EXIT} (residue findings on long-lived cluster)"
fi

step "6.F. Terminal times in the local time zone, machine formats in UTC"

# 0.23.0 prints the `Window:` line of text output in the machine's time
# zone. The image is FROM scratch, with no zoneinfo: a named zone must
# resolve against the database embedded in the binary rather than fall
# back to UTC, and a POSIX rule, which needs no database, works as well.
tz_run() {  # $1 = TZ, $2 = format, $3 = out file
  docker run --rm "${DOCKER_NET_FLAGS[@]}" -e "TZ=$1" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
    analyze --input /workdir/source.json --format "$2" > "$3" 2>/dev/null || true
}
window_line() { sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -m1 'Window:' | sed 's/^ *Window: *//' || true; }
tz_run UTC text "${TMP_DIR}/tz-utc.txt"
tz_run JST-9 text "${TMP_DIR}/tz-jst.txt"
tz_run Asia/Tokyo text "${TMP_DIR}/tz-named.txt"
tz_run UTC json "${TMP_DIR}/tz-utc.json"
tz_run JST-9 json "${TMP_DIR}/tz-jst.json"
# analysis.duration_ms is wall-clock (0 or 1 ms on this fixture), so it is left out of the comparison.
UTC_WINDOW="$(window_line "${TMP_DIR}/tz-utc.txt")"
JST_WINDOW="$(window_line "${TMP_DIR}/tz-jst.txt")"
NAMED_WINDOW="$(window_line "${TMP_DIR}/tz-named.txt")"
EXPECTED_JST="$(python3 - "${UTC_WINDOW}" <<'PY'
import sys
from datetime import datetime, timedelta
parts = sys.argv[1].split(" -> ")
try:
    shifted = [(datetime.strptime(p, "%Y-%m-%d %H:%M:%S") + timedelta(hours=9)).strftime("%Y-%m-%d %H:%M:%S") for p in parts]
    print(" -> ".join(shifted))
except ValueError:
    print("unparsable")
PY
)"
if [ -n "${UTC_WINDOW}" ] && [ "${JST_WINDOW}" = "${EXPECTED_JST}" ] \
   && [ "${NAMED_WINDOW}" = "${EXPECTED_JST}" ] \
   && cmp -s <(jq 'del(.analysis.duration_ms)' "${TMP_DIR}/tz-utc.json") \
             <(jq 'del(.analysis.duration_ms)' "${TMP_DIR}/tz-jst.json"); then
  ASSERT_LOCAL_TIME="PASS"
  ok "Window: ${UTC_WINDOW} (UTC) -> ${JST_WINDOW} (JST-9 and Asia/Tokyo), JSON identical"
else
  ASSERT_LOCAL_TIME="FAIL"
  warn "Window UTC='${UTC_WINDOW}' JST-9='${JST_WINDOW}' Asia/Tokyo='${NAMED_WINDOW}' expected '${EXPECTED_JST}', or the JSON differs between zones"
fi

step "7. Verdict"

# 6.D is informational. The 5 hard assertions are A formats coherence,
# A signature in JSON, B diff schema + new_findings, C cap loader.
if [ "${ASSERT_FORMATS}" = "PASS" ] \
   && [ "${ASSERT_COHERENCE}" = "PASS" ] \
   && [ "${ASSERT_SIG_JSON}" = "PASS" ] \
   && [ "${ASSERT_HTML_WARNINGS}" = "PASS" ] \
   && [ "${ASSERT_CSV_HEADERS}" = "PASS" ] \
   && [ "${ASSERT_DIFF_SCHEMA}" = "PASS" ] \
   && [ "${ASSERT_DIFF_NEW}" = "PASS" ] \
   && [ "${ASSERT_CAP}" = "PASS" ] \
   && [ "${ASSERT_LOCAL_TIME}" = "PASS" ]; then
  verdict="PASS"
else
  verdict="FAIL"
fi

cat > "${REPORT}" <<EOF
# Scenario report: ${SCENARIO}

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
perf-sentinel CLI image: ${IMAGE}
Source artefacts: ${CISL_DIR}/

## 6.A. Coverage of 4 formats + signature presence

| Format | Bytes | Source command |
| --- | --- | --- |
| json  | ${JSON_BYTES}  | analyze --format json (stdout) |
| sarif | ${SARIF_BYTES} | analyze --format sarif (stdout) |
| text  | ${TEXT_BYTES}  | analyze --format text (stdout) |
| html  | ${HTML_BYTES}  | report --input --output (separate subcommand) |

Coherence (JSON count == SARIF count): ${ASSERT_COHERENCE} (${JSON_COUNT}/${SARIF_COUNT})
Signature on every JSON finding: ${ASSERT_SIG_JSON} (${JSON_WITH_SIG}/${JSON_COUNT})
Signature in SARIF (informational, gap memory item 10): ${SIG_SARIF_NOTE}
Markdown format (informational, gap memory item 11): ${MARKDOWN_NOTE}
HTML warning banner present/absent: ${ASSERT_HTML_WARNINGS}
Findings CSV grouping headers: ${ASSERT_CSV_HEADERS}

## 6.B. Diff mode

Schema completeness (new/resolved/severity_changes/endpoint_metric_deltas): ${ASSERT_DIFF_SCHEMA}
new_findings count > 0: ${ASSERT_DIFF_NEW} (${NEW_FINDINGS})

## 6.C. Cap loader

Generated ack file: ${ACTUAL_SIZE} bytes
Cap loader rejection: ${ASSERT_CAP}

## 6.F. Local time on the terminal

Window line in UTC vs JST-9 and Asia/Tokyo (no zoneinfo in the image), JSON identical: ${ASSERT_LOCAL_TIME}

## 6.D. Sanity gate clean (informational)

${ASSERT_SANITY}

## Verdict: ${verdict}

EOF

if [ "${verdict}" = "PASS" ]; then
  color_green "output-formats-coverage: PASS"
  cat "${REPORT}"
else
  color_red "output-formats-coverage: FAIL"
  cat "${REPORT}"
  exit 1
fi
