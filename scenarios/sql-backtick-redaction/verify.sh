#!/usr/bin/env bash
# sql-backtick-redaction: validate the 0.9.2, 0.25.5 and 0.31.3 normalize/sql.rs
# changes on the local batch CLI path (no cluster, no daemon).
#
#   1. MySQL backtick identifiers are preserved verbatim by the normalizer,
#      including a NUMERIC backtick identifier (`2024`) that the pre-0.9.2
#      tokenizer would have masked to `?`. Bound `id` literals still collapse
#      to `?`, so the six occurrences group as one n_plus_one_sql.
#   2. PostgreSQL bracket/array string literals (ARRAY['secret','pii'],
#      data['ssn']) are MASKED, never leaked. This is the most important
#      security fix in the batch: no string literal may appear in analyze
#      output. `[` is deliberately NOT a special identifier state, so the
#      `'...'` string path masks the contents.
#   3. (0.25.5) MySQL / MariaDB double-quoted values are masked: OTLP spans
#      with db.system=mysql, db.system=mariadb and db.system.name=mysql each
#      give one n_plus_one_sql on `SELECT * FROM users WHERE email = ?`, and
#      example.com appears 0 times in the JSON and SARIF output. PostgreSQL
#      keeps `SELECT "Name" FROM "Users" WHERE "Id" = ?` verbatim. Native JSON
#      with no engine keeps the value (documented gap, pinned).
#   4. (0.31.3) Backslash escapes, hex and exponent literals: a `\'` inside
#      a MySQL or engine-less string stays in its string, a SQL Server string
#      ending on `\` ends there, and `0x1F` / `2.5e-3` are one ? each. Four
#      traces, one N+1 each, and secret / corp.test appear 0 times in the
#      JSON and SARIF output.
#
# All fixtures are committed (native SpanEvent JSON, one OTLP JSON).
# fixtures/generate.py regenerates them (stdlib-only). Uses the local release binary built from
# the perf-sentinel checkout under test.
set -euo pipefail

SCENARIO="sql-backtick-redaction"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
rm -f "${REPORT}"  # die() prints it, never show a previous run's verdict
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCENARIO}.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"

BT_TEMPLATE=""
AR_TEMPLATE=""

step "Backtick identifiers preserved (incl. numeric \`2024\`), N+1 grouped"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/backtick.native.json" --format json \
  > "${TMP_DIR}/backtick.json" 2>"${TMP_DIR}/backtick.err" \
  || die "analyze failed on backtick.native.json: $(tail -2 "${TMP_DIR}/backtick.err")"

BT_TEMPLATE="$(python3 -c "
import json
r=json.load(open('${TMP_DIR}/backtick.json'))
n1=[f for f in r['findings'] if f.get('type')=='n_plus_one_sql']
assert len(n1)==1, 'expected exactly 1 n_plus_one_sql, got %d (%s)' % (len(n1), [f.get('type') for f in r['findings']])
print(n1[0]['pattern']['template'])
")" || die "backtick: ${BT_TEMPLATE:-no n_plus_one_sql finding}"

# shellcheck disable=SC2016  # literal backticks, nothing to expand
EXPECTED_BT='SELECT `name`, `col2` FROM `2024` WHERE `id` = ?'
[ "${BT_TEMPLATE}" = "${EXPECTED_BT}" ] \
  || die "backtick template mismatch: got [${BT_TEMPLATE}] want [${EXPECTED_BT}]"
# Numeric backtick id must NOT have been masked to `?`.
# shellcheck disable=SC2016
echo "${BT_TEMPLATE}" | grep -qF '`2024`' || die "numeric backtick \`2024\` was masked (pre-0.9.2 regression)"
# shellcheck disable=SC2016
echo "${BT_TEMPLATE}" | grep -qF '`col2`' || die "alphanumeric backtick \`col2\` not preserved"
ok "template: ${BT_TEMPLATE}"

# --- 2. bracket / array redaction (security) --------------------------------
step "PostgreSQL bracket/array string literals masked, no leak"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/array-redaction.native.json" --format json \
  > "${TMP_DIR}/array.json" 2>"${TMP_DIR}/array.err" \
  || die "analyze failed on array-redaction.native.json: $(tail -2 "${TMP_DIR}/array.err")"

AR_TEMPLATE="$(python3 -c "
import json
r=json.load(open('${TMP_DIR}/array.json'))
fs=[f for f in r['findings']]
assert fs, 'no finding fired on the array fixture'
print(fs[0]['pattern']['template'])
")" || die "array: ${AR_TEMPLATE:-no finding}"

echo "${AR_TEMPLATE}" | grep -qF 'ARRAY[?, ?]' || die "ARRAY literals not masked: [${AR_TEMPLATE}]"
echo "${AR_TEMPLATE}" | grep -qF 'data[?]'     || die "subscript literal not masked: [${AR_TEMPLATE}]"
# Whole-output leak scan: params are never serialized, so any hit is a real leak.
if grep -oiE "secret|pii|ssn" "${TMP_DIR}/array.json"; then
  die "string literal leaked into analyze JSON output"
fi
ok "template: ${AR_TEMPLATE}  (no secret/pii/ssn leak)"

# --- 3. HTML render: masked template renders + exemplar surface check -------
# The 0.9.2 security fix is the NORMALIZED TEMPLATE (signature/grouping path),
# proven clean above on the canonical `analyze --format json` output. The HTML
# report ALSO embeds a raw example span (`target` = captured db.statement) as
# an exemplar. That raw exemplar is rendered verbatim and is OUTSIDE the 0.9.2
# commits under test (normalize/sql.rs only, the report renderer is untouched).
# So we assert the masked template renders, and we OBSERVE, non-fatally,
# whether the raw exemplar surfaces literals from un-sanitized input.
step "HTML report: masked template renders; raw exemplar surface observed"
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${FIX}/array-redaction.native.json" \
  --output "${TMP_DIR}/array.html" >/dev/null 2>&1 || die "report --output failed"
grep -qF 'ARRAY[?, ?]' "${TMP_DIR}/array.html" || die "masked template absent from HTML report"
HTML_EXEMPLAR_LEAK="no"
if grep -qF "ARRAY['secret'" "${TMP_DIR}/array.html"; then
  HTML_EXEMPLAR_LEAK="yes"
  color_red "    note: HTML embeds the raw exemplar statement (ARRAY['secret', 'pii'])."
  color_red "          Pre-existing report-renderer behaviour, NOT touched by 0.9.2;"
  color_red "          the normalize fix (template/signature) is clean. Flag upstream."
fi
ok "masked template present in HTML; raw-exemplar leak=${HTML_EXEMPLAR_LEAK}"

# --- 4. MySQL / MariaDB double-quoted values masked (0.25.5) -----------------
# OTLP CLIENT spans, engine from db.system / db.system.name. MySQL and MariaDB
# read "..." as a string literal, so the address must collapse to ? and the six
# spans of each trace group as one N+1. PostgreSQL keeps "..." as identifiers.
# Before 0.25.5 the value stayed in the template: one template per address, no
# N+1, and the address leaked into JSON and SARIF. HTML is not scanned, it
# embeds raw spans by design (section 3).
step "MySQL/MariaDB double-quoted values masked, PostgreSQL identifiers kept"
for fmt in json sarif; do
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/double-quote.otlp.json" --format "${fmt}" \
    > "${TMP_DIR}/dq.${fmt}" 2>"${TMP_DIR}/dq.err" \
    || die "analyze --format ${fmt} failed on double-quote.otlp.json: $(tail -2 "${TMP_DIR}/dq.err")"
done
# Every check runs before the leg fails, so a regression shows all its faces.
DQ_FAILS=0
dq_fail() { color_red "    FAIL: $*"; DQ_FAILS=$((DQ_FAILS + 1)); }
DQ_LINES="$(python3 - "${TMP_DIR}/dq.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
want = [
    ("da", "db.system=mysql", "SELECT * FROM users WHERE email = ?"),
    ("db", "db.system=mariadb", "SELECT * FROM users WHERE email = ?"),
    ("dd", "db.system.name=mysql", "SELECT * FROM users WHERE email = ?"),
    ("dc", "db.system=postgresql", 'SELECT "Name" FROM "Users" WHERE "Id" = ?'),
]
for suffix, engine, template in want:
    n1 = [f["pattern"]["template"] for f in r["findings"]
          if f.get("type") == "n_plus_one_sql" and f.get("trace_id", "").endswith(suffix)]
    if n1 == [template]:
        print("ok %s: one n_plus_one_sql on [%s]" % (engine, template))
    else:
        print("FAIL %s: want one n_plus_one_sql [%s], got %s" % (engine, template, n1))
PY
)" || die "could not parse ${TMP_DIR}/dq.json"
while IFS= read -r line; do
  case "${line}" in
    "ok "*) ok "${line#ok }" ;;
    *)      dq_fail "${line#FAIL }" ;;
  esac
done <<< "${DQ_LINES}"
# The SARIF scan alone would pass on an empty run, so require its 4 N+1 first.
SARIF_N1="$(python3 -c "
import json,sys
r=json.load(open(sys.argv[1]))
print(sum(1 for x in r['runs'][0]['results'] if x.get('ruleId')=='n_plus_one_sql'))" "${TMP_DIR}/dq.sarif")" \
  || die "could not parse ${TMP_DIR}/dq.sarif"
if [ "${SARIF_N1}" = "4" ]; then
  ok "sarif output holds 4 n_plus_one_sql results"
else
  dq_fail "sarif output: want 4 n_plus_one_sql results, got ${SARIF_N1}"
fi
for fmt in json sarif; do
  hits="$({ grep -oF 'example.com' "${TMP_DIR}/dq.${fmt}" || true; } | wc -l | tr -d ' ')"
  if [ "${hits}" = "0" ]; then
    ok "example.com appears 0 times in the ${fmt} output"
  else
    dq_fail "double-quoted address leaked: example.com appears ${hits} time(s) in the ${fmt} output"
  fi
done
[ "${DQ_FAILS}" = "0" ] || die "${DQ_FAILS} double-quote check(s) failed"

# Documented gap: native JSON whose operation is the SQL verb names no engine,
# so "..." stays an identifier. Pinned so a silent change of the default shows.
step "Native JSON without an engine keeps the double-quoted value (documented gap)"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/double-quote-gap.native.json" --format json \
  > "${TMP_DIR}/dq-gap.json" 2>"${TMP_DIR}/dq-gap.err" \
  || die "analyze failed on double-quote-gap.native.json: $(tail -2 "${TMP_DIR}/dq-gap.err")"
GAP_TYPES="$(python3 -c "
import json,sys
print(' '.join(sorted({f.get('type') for f in json.load(open(sys.argv[1]))['findings']})))" "${TMP_DIR}/dq-gap.json")" \
  || die "could not parse ${TMP_DIR}/dq-gap.json"
case " ${GAP_TYPES} " in
  *" n_plus_one_sql "*) die "gap changed: the engine-less double-quoted values now group as an N+1" ;;
esac
# The value reaches the output only through the serialized_calls suggestion,
# so a missing serialized_calls says nothing about the normalizer default.
case " ${GAP_TYPES} " in
  *" serialized_calls "*) ;;
  *) die "gap leg cannot judge: no serialized_calls finding (got [${GAP_TYPES}]), the detector that carries the value changed" ;;
esac
grep -qF 'gap-1@native.test' "${TMP_DIR}/dq-gap.json" \
  || die "gap changed: the double-quoted value no longer reaches the output (update the scenario and the docs)"
ok "engine-less native JSON keeps \"gap-<n>@native.test\", no N+1 forms"

# --- 5. backslash escapes, hex and exponent literals (0.31.3) ---------------
# MySQL and an engine-less span read `\'` as an escaped quote, so the string
# holds `it\'s secret-<n>` and the template keeps nothing of it. SQL Server
# strings follow the standard, so `'C:\Temp\'` ends on its second quote and
# the owner address after it is a string of its own. Before 0.31.3, E1 and E2
# leaked `s secret-?` into the template and E4 split into one template per
# value. E3 passes on 0.31.2 too: it guards against escaping a backslash on a
# standard engine, which would leak the owner address.
step "Backslash escapes follow the engine, hex and exponent literals collapse"
for fmt in json sarif; do
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/literal-forms.otlp.json" --format "${fmt}" \
    > "${TMP_DIR}/lf.${fmt}" 2>"${TMP_DIR}/lf.err" \
    || die "analyze --format ${fmt} failed on literal-forms.otlp.json: $(tail -2 "${TMP_DIR}/lf.err")"
done
LF_FAILS=0
lf_fail() { color_red "    FAIL: $*"; LF_FAILS=$((LF_FAILS + 1)); }
LF_LINES="$(python3 - "${TMP_DIR}/lf.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
want = [
    ("e1", "db.system=mysql", "SELECT * FROM users WHERE note = ?"),
    ("e2", "no engine", "SELECT * FROM users WHERE note = ?"),
    ("e3", "db.system=mssql", "SELECT * FROM files WHERE path = ? AND owner = ?"),
    ("e4", "db.system=postgresql", "SELECT * FROM metrics WHERE h = ? AND v = ?"),
]
for suffix, engine, template in want:
    n1 = [f["pattern"]["template"] for f in r["findings"]
          if f.get("type") == "n_plus_one_sql" and f.get("trace_id", "").endswith(suffix)]
    if n1 == [template]:
        print("ok %s: one n_plus_one_sql on [%s]" % (engine, template))
    else:
        print("FAIL %s: want one n_plus_one_sql [%s], got %s" % (engine, template, n1))
PY
)" || die "could not parse ${TMP_DIR}/lf.json"
while IFS= read -r line; do
  case "${line}" in
    "ok "*) ok "${line#ok }" ;;
    *)      lf_fail "${line#FAIL }" ;;
  esac
done <<< "${LF_LINES}"
LF_SARIF_N1="$(python3 -c "
import json,sys
r=json.load(open(sys.argv[1]))
print(sum(1 for x in r['runs'][0]['results'] if x.get('ruleId')=='n_plus_one_sql'))" "${TMP_DIR}/lf.sarif")" \
  || die "could not parse ${TMP_DIR}/lf.sarif"
if [ "${LF_SARIF_N1}" = "4" ]; then
  ok "sarif output holds 4 n_plus_one_sql results"
else
  lf_fail "sarif output: want 4 n_plus_one_sql results, got ${LF_SARIF_N1}"
fi
for fmt in json sarif; do
  hits="$({ grep -oE 'secret|corp\.test' "${TMP_DIR}/lf.${fmt}" || true; } | wc -l | tr -d ' ')"
  if [ "${hits}" = "0" ]; then
    ok "secret and corp.test appear 0 times in the ${fmt} output"
  else
    lf_fail "string content leaked: secret or corp.test appears ${hits} time(s) in the ${fmt} output"
  fi
done
[ "${LF_FAILS}" = "0" ] || die "${LF_FAILS} literal-form check(s) failed"

# --- verdict ----------------------------------------------------------------
# PASS reflects the 0.9.2, 0.25.5 and 0.31.3 changes under test (normalize/sql.rs). The HTML
# exemplar observation is reported but does not gate this scenario.
verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Binary: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo ""
  echo "| check | result |"
  echo "|---|---|"
  echo "| backtick template | \`${BT_TEMPLATE}\` |"
  echo "| numeric backtick \`2024\` preserved | yes |"
  echo "| array/subscript template | \`${AR_TEMPLATE}\` |"
  echo "| secret/pii/ssn leak in analyze JSON | none |"
  echo "| masked template renders in HTML | yes |"
  echo "| raw exemplar leak in HTML (out of scope) | ${HTML_EXEMPLAR_LEAK} |"
  echo "| mysql/mariadb/db.system.name double-quoted value masked, one N+1 each | yes |"
  echo "| postgresql double-quoted identifiers kept | yes |"
  echo "| example.com in OTLP analyze JSON/SARIF | 0 |"
  echo "| engine-less native JSON keeps double-quoted value (documented gap) | yes |"
  echo "| mysql and engine-less backslash-escaped quote kept in its string, one N+1 each | yes |"
  echo "| mssql string ends on a trailing backslash, one N+1 | yes |"
  echo "| postgresql hex and exponent literals collapse, one N+1 | yes |"
  echo "| secret/corp.test in OTLP analyze JSON/SARIF | 0 |"
  echo ""
  if [ "${HTML_EXEMPLAR_LEAK}" = "yes" ]; then
    echo "> Observation: the normalized template (the 0.9.2 fix) masks bracket/array"
    echo "> string literals correctly on the canonical \`analyze --format json\` path."
    echo "> The HTML report additionally embeds a raw example span whose \`target\` is"
    echo "> the captured db.statement, so un-sanitized literals still appear in that"
    echo "> exemplar. The report renderer is NOT part of the 0.9.2 commits under test"
    echo "> (normalize/sql.rs only). Pre-existing behaviour, worth flagging upstream."
    echo ""
  fi
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
