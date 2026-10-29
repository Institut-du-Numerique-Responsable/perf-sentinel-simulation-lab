#!/usr/bin/env bash
# findings-page-filters: the 0.21.0 reading contract of `GET /api/findings`,
# and the fold behind it.
#
# 0.21.0 adds two parameters, `grouping` and `offset`, makes an empty filter
# value mean no filter, rewrites the fold so that only the page a read keeps
# is materialised, and bounds the `serialized_calls` suggestion. Nothing in
# the lab exercised any of it: the only forms in use were `service`, `type`,
# `severity`, `limit`, `since_ms`, `until_ms` and `include_acked`, and no
# scenario ever compared what the fold returns against a published release.
#
# Five claims. Four of them carry a counter-proof against a before-the-feature
# baseline (0.20.2), because that is the only way to tell a real change from a
# lab that cannot see one: the 0.20.2 ledger entry records a release whose
# behaviour no scenario here could distinguish, and a leg that passes on both
# builds proves nothing about the new one. The fifth, D, is a comparison
# against the latest release instead, see below.
#
#   A. Grouping. `?grouping=<value>` partitions the listing exactly, on the
#      value `label_values(perf_sentinel_findings_total, grouping)` offers,
#      which is what lets one Grafana variable drive both dashboards. The
#      baseline ignores the parameter and returns everything.
#   B. Empty is absent. An empty, blank or `+` filter value is no filter, on
#      all four string filters, and a value is trimmed. The baseline matched
#      those literally and returned nothing, so this is a behaviour change a
#      client can see: the leg records it rather than assuming it away.
#   C. Paging. `offset` walks the folded listing with no gap and no overlap,
#      past the end it is an empty 200, and, the trap written nowhere else, a
#      page shortened by the ack screen is not the last page: the screen runs
#      after `offset` and `limit`.
#   D. The fold is unchanged. Same corpus into the daemon under test and one
#      on the latest release, same rows, same representative, same counts,
#      batch by batch. `perf(daemon)` promised a cheaper fold, not a different
#      one, and only this comparison holds it to that. Not against 0.20.2:
#      0.26.2 deliberately changed which instance represents a tie (smallest
#      trace id for a slow trace, one finding order per input), so every
#      build from 0.26.2 on differs from 0.20.2 on representatives without a
#      fold regression. Batch by batch and not row by row: one analysis
#      batch shares one `stored_at_ms`, the listing is ordered on that
#      stamp, and the order inside a batch is the insertion order, which
#      moves between two runs of the SAME binary. The first full pass caught
#      exactly that.
#   E. `serialized_calls` names the block instead of carrying it: at most
#      three distinct templates, each cut at 120 characters, ` -> ...` when
#      more follows, and the count, total and parallel estimate untouched.
#      Batch `analyze`, no daemon, since this is the detector's output.
#
# Self-contained: local release binary, Docker, python3, curl. No cluster.
# Docker is a hard prerequisite here, unlike in the local-binary scenarios:
# every leg compares against one of two published images and a scenario
# that quietly skips them reads exactly like one that passed.
set -uo pipefail

SCENARIO="findings-page-filters"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
TRACEGEN="${LAB_ROOT}/tools/tracegen/tracegen.py"
FOLD="${SCENARIO_DIR}/fold_compare.py"
FIXTURE_GEN="${SCENARIO_DIR}/serialized_fixture.py"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

# The before-the-feature release, the counter-proof of legs A, B, C and E.
# Fixed on purpose: those legs need a build without 0.21.0's parameters.
BASELINE_IMAGE="${BASELINE_IMAGE:-ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.20.2}"
BASELINE_NAME="fpf-baseline-$$"
# The latest release, the reference of leg D. Bump it with the pin in
# manifests/perf-sentinel-daemon.yaml, same digest.
FOLD_BASELINE_IMAGE="${FOLD_BASELINE_IMAGE:-ghcr.io/institut-du-numerique-responsable/perf-sentinel@sha256:c09459b145cb68cbb2874013081372939db47b491fa8eedadb8d33ff2308cbc7}"  # 0.37.1
FOLD_BASELINE_NAME="fpf-fold-baseline-$$"

DAEMON_HTTP_PORT="${FPF_DAEMON_HTTP_PORT:-14828}"
DAEMON_GRPC_PORT="${FPF_DAEMON_GRPC_PORT:-14827}"
BASELINE_HTTP_PORT="${FPF_BASELINE_HTTP_PORT:-14838}"
FOLD_BASELINE_HTTP_PORT="${FPF_FOLD_BASELINE_HTTP_PORT:-14839}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
BASELINE_URL="http://127.0.0.1:${BASELINE_HTTP_PORT}"
FOLD_BASELINE_URL="http://127.0.0.1:${FOLD_BASELINE_HTTP_PORT}"

# Two tenants, so leg A has something to partition. One would make the
# baseline's "ignores the parameter" answer and the correct one identical.
TENANT_A="fpf-tenant-a"
TENANT_B="fpf-tenant-b"
# The nonce is what makes the two sides comparable: tracegen derives its
# service names from it and picks a fresh one per process, so two runs of the
# same seed would otherwise differ on every `service` field.
NONCE="${FPF_NONCE:-ab}"
SEED_A="${FPF_SEED_A:-4321}"
SEED_B="${FPF_SEED_B:-9876}"
SERIALIZED_CALLS="${FPF_SERIALIZED_CALLS:-40}"
SERIALIZED_TEMPLATE_BYTES="${FPF_SERIALIZED_TEMPLATE_BYTES:-4096}"
# The documented bound, asserted rather than recomputed: a silent change
# upstream has to show up here.
SUGGESTION_MAX_BYTES=1000
SUGGESTION_TEMPLATE_CHARS=120

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}/acks"
# A stale PASS report must not outlive a failing re-run.
rm -f "${REPORT}"

color_blue()   { printf '\033[34m%s\033[0m\n' "$*"; }
color_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
color_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
color_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_yellow "    warn: $*"; }
die()  { color_red "    error: $*"; exit 1; }

FAILURES=0
declare -a RESULTS=()
pass() { ok "$2"; RESULTS+=("$1|PASS|$2"); }
fail() { color_red "    FAIL: $2"; RESULTS+=("$1|FAIL|$2"); FAILURES=$((FAILURES + 1)); }

DAEMON_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null
  docker rm -f "${BASELINE_NAME}" "${FOLD_BASELINE_NAME}" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# --- prerequisites -----------------------------------------------------------

step "Prerequisites"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no release binary at ${PERF_SENTINEL_LOCAL_BIN}, run: cd ${PERF_SENTINEL_REPO_PATH} && cargo build --release --workspace"
command -v docker >/dev/null 2>&1 \
  || die "docker is required: every leg compares against ${BASELINE_IMAGE} or ${FOLD_BASELINE_IMAGE}"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
python3 -c 'import opentelemetry.proto' 2>/dev/null \
  || die "tracegen's http-pb protocol needs opentelemetry-proto: pip install -r ${LAB_ROOT}/tools/tracegen/requirements.txt"
for image in "${BASELINE_IMAGE}" "${FOLD_BASELINE_IMAGE}"; do
  docker pull -q "${image}" >/dev/null 2>&1 \
    || warn "could not refresh ${image}, using the local copy"
  docker image inspect "${image}" >/dev/null 2>&1 \
    || die "baseline image unavailable: ${image}"
done
VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version 2>/dev/null | awk '{print $2}')"
PRODUCT_COMMIT="$(git -C "${PERF_SENTINEL_REPO_PATH}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ok "under test: ${PERF_SENTINEL_LOCAL_BIN} ${VERSION} (${PRODUCT_COMMIT})"
ok "baseline:   ${BASELINE_IMAGE} (legs A, B, C, E)"
ok "fold:       ${FOLD_BASELINE_IMAGE} (leg D)"

# --- helpers -----------------------------------------------------------------

ack_section() {  # $1 = storage path, or "" to run without an ack store
  # Only the side under test needs one: leg C writes an ack there. The
  # baseline runs in a container as a non-root user, so a host path it was
  # handed would fail to open and take the whole run down before any leg.
  # Explicit either way, never the default location, which is the operator's
  # own store shared with every daemon this machine ever ran.
  if [ -z "$1" ]; then
    printf '[daemon.ack]\nenabled = false\n'
  else
    printf '[daemon.ack]\nenabled = true\nstorage_path = "%s"\n' "$1"
  fi
}

write_config() {  # $1 = target file, $2 = listen address, $3 = http, $4 = grpc, $5 = ack path or "" for no ack store
  cat > "$1" <<EOF
[daemon]
listen_address = "$2"
listen_port_http = $3
listen_port_grpc = $4
api_enabled = true
# Every trace's spans arrive in one batch, so a short TTL only shortens the
# wait before the findings are readable.
trace_ttl_ms = 1000
# Well above what the corpus folds into: this scenario is about which rows a
# page returns, and an eviction mid-run would silently change the answer.
max_retained_findings = 20000

$(ack_section "$5")

[detection]
n_plus_one_min_occurrences = 5
slow_query_threshold_ms = 100
slow_query_min_occurrences = 3
# Pinned rather than left to the product default, as grouping-identity does:
# if the default list ever drops k8s.namespace.name, leg A must fail as the
# config drift it is, not as a filtering regression.
grouping_attributes = ["k8s.namespace.name", "service.namespace"]
EOF
}

wait_ready() {  # $1 = url
  for _ in $(seq 1 80); do
    curl -fsS "$1/api/status" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

start_local_daemon() {
  # Require the port to fall silent: a leftover daemon from an aborted run
  # would answer readiness and every leg below would grade the wrong process.
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
    && die "something already serves ${DAEMON_URL}, leftover daemon from a previous run?"
  write_config "${TMP_DIR}/daemon.toml" 127.0.0.1 "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}" "${TMP_DIR}/acks/acks.jsonl"
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  wait_ready "${DAEMON_URL}" \
    || die "the daemon under test never became ready: $(tail -3 "${TMP_DIR}/daemon.log")"
}

start_baseline_daemon() {  # $1 = container name, $2 = image, $3 = host http port
  # Same config for both containers: they listen on the same in-container
  # ports and only the published one differs.
  write_config "${TMP_DIR}/baseline.toml" 0.0.0.0 14318 14317 ""
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --name "$1" \
    -p "$3:14318" \
    -v "${TMP_DIR}/baseline.toml:/etc/perf-sentinel/config.toml:ro" \
    "$2" watch --config /etc/perf-sentinel/config.toml >/dev/null \
    || die "baseline container failed to start on $2"
  wait_ready "http://127.0.0.1:$3" \
    || die "baseline never became ready on $2: $(docker logs "$1" 2>&1 | tail -3)"
}

SEND_FAILURES=0
send() {  # $1 = endpoint url, $2 = tenant, $3 = seed, $4 = services, $5 = duration
  python3 "${TRACEGEN}" --protocol http-pb --endpoint "$1" \
    --duration "$5" --tps 20 --batch-traces 10 --services "$4" \
    --service-prefix fpf --run-nonce "${NONCE}" --seed "$3" \
    --mix n_plus_one:40,slow:20,redundant:20,chatty:10,clean:10 \
    --resource-attribute "k8s.namespace.name=$2" \
    >> "${TMP_DIR}/send.log" 2>> "${TMP_DIR}/send.err" \
    || SEND_FAILURES=$((SEND_FAILURES + 1))
}

check_sends() {  # $1 = leg name
  [ "${SEND_FAILURES}" -eq 0 ] && return 0
  die "${SEND_FAILURES} tracegen run(s) failed before leg $1, see ${TMP_DIR}/send.err; the assertions below would grade an incomplete corpus"
}

fetch() {  # $1 = base url, $2 = query, $3 = out file
  curl -fsS "$1/api/findings?$2" -o "$3" \
    || die "GET $1/api/findings?$2 failed (daemon gone?)"
}

rows() {  # $1 = base url, $2 = query -> row count on stdout
  local out="${TMP_DIR}/row-count.json"
  fetch "$1" "$2" "${out}"
  python3 "${FOLD}" count "${out}"
}

# --- corpus ------------------------------------------------------------------

step "Start the three daemons and feed them the same corpus"
start_local_daemon
start_baseline_daemon "${BASELINE_NAME}" "${BASELINE_IMAGE}" "${BASELINE_HTTP_PORT}"
start_baseline_daemon "${FOLD_BASELINE_NAME}" "${FOLD_BASELINE_IMAGE}" "${FOLD_BASELINE_HTTP_PORT}"
for url in "${DAEMON_URL}" "${BASELINE_URL}" "${FOLD_BASELINE_URL}"; do
  send "${url}" "${TENANT_A}" "${SEED_A}" 6 8
  send "${url}" "${TENANT_B}" "${SEED_B}" 4 6
done
check_sends "setup"
# One TTL plus the analysis worker's own tick, so the last batch is folded in
# before anything below reads a page.
sleep 4

TOTAL="$(rows "${DAEMON_URL}" "include_acked=true&limit=1000")"
[ "${TOTAL}" -gt 50 ] \
  || die "only ${TOTAL} folded rows under test, the corpus did not land; see ${TMP_DIR}/daemon.log"
BASE_TOTAL="$(rows "${BASELINE_URL}" "include_acked=true&limit=1000")"
[ "${BASE_TOTAL}" -eq "${TOTAL}" ] \
  || die "${BASELINE_IMAGE} and the build under test folded the same corpus into different row counts (${BASE_TOTAL} vs ${TOTAL}); every comparison below would grade that instead"
FOLD_TOTAL="$(rows "${FOLD_BASELINE_URL}" "include_acked=true&limit=1000")"
[ "${FOLD_TOTAL}" -eq "${TOTAL}" ] \
  || die "${FOLD_BASELINE_IMAGE} and the build under test folded the same corpus into different row counts (${FOLD_TOTAL} vs ${TOTAL}); leg D would grade that instead"
ok "${TOTAL} folded rows on each of the three daemons"

# The feature probe, and its floor. A release branch keeps the previous
# version in Cargo.toml until tag time, so `--version` cannot answer whether
# this build has the parameter. From 0.21.0 on, a build that ignores it is
# not an old binary, it is a moved contract: fail rather than skip. A gate
# that skips forever is indistinguishable from one that passes, and this lab
# has shipped that exact mistake with version-pinned images.
PROBE="$(rows "${DAEMON_URL}" "include_acked=true&limit=1000&grouping=nothing-carries-this")"
[ "${PROBE}" -eq 0 ] \
  || die "the build under test ignores ?grouping= (${PROBE} rows for a value no finding carries): it predates 0.21.0, or the parameter was renamed"

# --- A. grouping partitions the listing --------------------------------------

step "A. ?grouping= partitions the listing on the Prometheus label's value"
A_FAILED=0
A_ROWS="$(rows "${DAEMON_URL}" "include_acked=true&limit=1000&grouping=${TENANT_A}")"
B_ROWS="$(rows "${DAEMON_URL}" "include_acked=true&limit=1000&grouping=${TENANT_B}")"
if [ "$((A_ROWS + B_ROWS))" -ne "${TOTAL}" ]; then
  fail "A.partition" "${TENANT_A} (${A_ROWS}) + ${TENANT_B} (${B_ROWS}) != ${TOTAL} unfiltered rows"
  A_FAILED=1
fi
[ "${A_ROWS}" -gt 0 ] && [ "${B_ROWS}" -gt 0 ] || {
  fail "A.partition" "one side of the partition is empty (${A_ROWS}, ${B_ROWS}): the corpus did not carry both tenants"
  A_FAILED=1
}
# The join that justifies the parameter: the value a Grafana variable reads
# from `label_values(...)` must be the one this filter takes, with no
# conversion. Anything else and the shipped dashboard filters on nothing.
curl -fsS "${DAEMON_URL}/metrics" > "${TMP_DIR}/metrics.txt" \
  || die "could not scrape ${DAEMON_URL}/metrics"
grep '^perf_sentinel_findings_total' "${TMP_DIR}/metrics.txt" \
  | grep -o 'grouping="[^"]*"' | sed 's/grouping="\(.*\)"/\1/' | sort -u \
  > "${TMP_DIR}/label-groupings.txt"
fetch "${DAEMON_URL}" "include_acked=true&limit=1000" "${TMP_DIR}/all.json"
python3 "${FOLD}" groupings "${TMP_DIR}/all.json" > "${TMP_DIR}/api-groupings.txt"
if ! diff -q "${TMP_DIR}/label-groupings.txt" "${TMP_DIR}/api-groupings.txt" >/dev/null; then
  fail "A.join" "the grouping values on /metrics and in the API differ, so a dashboard variable cannot drive the filter"
  diff "${TMP_DIR}/label-groupings.txt" "${TMP_DIR}/api-groupings.txt" | head -6
  A_FAILED=1
fi
# The counter-proof. Without it the leg passes on any build: 0.20.2 ignores
# an unknown parameter and answers the whole listing, which for a single
# tenant is indistinguishable from filtering correctly.
BASE_A="$(rows "${BASELINE_URL}" "include_acked=true&limit=1000&grouping=${TENANT_A}")"
if [ "${BASE_A}" -ne "${BASE_TOTAL}" ]; then
  fail "A.counter-proof" "${BASELINE_IMAGE} returned ${BASE_A} of ${BASE_TOTAL} rows for ?grouping=, so it already filters and this leg proves nothing about 0.21.0"
  A_FAILED=1
fi
[ "${A_FAILED}" -eq 0 ] \
  && pass "A" "${A_ROWS} + ${B_ROWS} = ${TOTAL}, on the same values /metrics labels, where the baseline returns all ${BASE_TOTAL}"

# --- B. an empty filter value is no filter -----------------------------------

step "B. an empty, blank or plus-encoded filter value is no filter"
B_FAILED=0
for filter in grouping service type severity; do
  for value in "" "%20" "+"; do
    got="$(rows "${DAEMON_URL}" "include_acked=true&limit=1000&${filter}=${value}")"
    if [ "${got}" -ne "${TOTAL}" ]; then
      fail "B.${filter}" "?${filter}=${value:-<empty>} returned ${got} of ${TOTAL} rows, so a Grafana All option filters everything out"
      B_FAILED=1
    fi
  done
done
# The trim, the other half of the same rule.
SOME_SERVICE="$(python3 -c "
import json
rows = json.load(open('${TMP_DIR}/all.json'))
print(rows[0]['finding']['service'])")"
PLAIN="$(rows "${DAEMON_URL}" "include_acked=true&limit=1000&service=${SOME_SERVICE}")"
PADDED="$(rows "${DAEMON_URL}" "include_acked=true&limit=1000&service=%20${SOME_SERVICE}%20")"
if [ "${PLAIN}" -ne "${PADDED}" ] || [ "${PLAIN}" -eq 0 ]; then
  fail "B.trim" "service=${SOME_SERVICE} returned ${PLAIN} rows but the space-padded form returned ${PADDED}"
  B_FAILED=1
fi
# The counter-proof, and the reason this leg exists at all: on 0.20.2 an
# empty value was an exact match on "" and returned nothing. A client that
# sent one is reading a different answer from 0.21.0, and the lab records
# that rather than discovering it in an issue.
BASE_EMPTY="$(rows "${BASELINE_URL}" "include_acked=true&limit=1000&severity=")"
if [ "${BASE_EMPTY}" -ne 0 ]; then
  fail "B.counter-proof" "${BASELINE_IMAGE} returned ${BASE_EMPTY} rows for ?severity=, so the change this leg documents is not the one that shipped"
  B_FAILED=1
fi
[ "${B_FAILED}" -eq 0 ] \
  && pass "B" "12 empty-value forms and the trim all return the whole listing, where the baseline returns 0"

# --- C. offset pages the folded listing --------------------------------------

step "C. ?offset= pages the folded rows with no gap and no overlap"
C_FAILED=0
fetch "${DAEMON_URL}" "include_acked=true&limit=1000" "${TMP_DIR}/whole.json"
python3 "${FOLD}" signatures "${TMP_DIR}/whole.json" > "${TMP_DIR}/whole-sigs.txt"
: > "${TMP_DIR}/paged-sigs.txt"
PAGE=25
off=0
while [ "${off}" -lt "${TOTAL}" ]; do
  fetch "${DAEMON_URL}" "include_acked=true&limit=${PAGE}&offset=${off}" "${TMP_DIR}/page-${off}.json"
  python3 "${FOLD}" signatures "${TMP_DIR}/page-${off}.json" >> "${TMP_DIR}/paged-sigs.txt"
  off=$((off + PAGE))
done
if ! diff -q "${TMP_DIR}/whole-sigs.txt" "${TMP_DIR}/paged-sigs.txt" >/dev/null; then
  fail "C.pages" "walking the listing ${PAGE} rows at a time did not reproduce the single read, in order"
  diff "${TMP_DIR}/whole-sigs.txt" "${TMP_DIR}/paged-sigs.txt" | head -6
  C_FAILED=1
fi
# Keyed on (signature, grouping), not the signature: the fold groups on the
# pair, so the same service name under two namespaces is legitimately two
# rows, and this corpus has exactly that. The check is not the diff above
# repeated: it would catch a fold that emitted one row twice, which the diff
# would compare equal against a single read carrying the same duplicate.
python3 "${FOLD}" rowkeys "${TMP_DIR}/whole.json" > "${TMP_DIR}/whole-keys.txt"
DUPES="$(sort "${TMP_DIR}/whole-keys.txt" | uniq -d | wc -l | tr -d ' ')"
[ "${DUPES}" -eq 0 ] || { fail "C.overlap" "${DUPES} (signature, grouping) row(s) appear twice in one read"; C_FAILED=1; }
PAST_END="$(rows "${DAEMON_URL}" "include_acked=true&limit=1000&offset=$((TOTAL + 1000))")"
[ "${PAST_END}" -eq 0 ] || { fail "C.past-end" "an offset past the end returned ${PAST_END} rows"; C_FAILED=1; }
# The trap: the ack screen runs after `offset` and `limit`, so a short page
# is not the last page. A client reading `len() < limit` as the end of the
# listing silently stops at the first acked row, and nothing else says so.
fetch "${DAEMON_URL}" "include_acked=true&limit=10&offset=0" "${TMP_DIR}/first10.json"
# URL-encoded, and curl kept off its own globbing: a signature carries the
# normalized endpoint, so `{id}` is in most of them, and curl reads a brace
# as a glob. Unencoded, the ack landed on a signature no finding has, which
# the daemon accepts (an unmatched ack is a warning, not an error), so the
# probe below silently graded a listing nothing had been acked in.
SIG="$(python3 -c "
import json, urllib.parse
sig = json.load(open('${TMP_DIR}/first10.json'))[4]['finding']['signature']
print(urllib.parse.quote(sig, safe=''))")"
ACK_STATUS="$(curl -fsS --globoff -o "${TMP_DIR}/ack.json" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"by":"findings-page-filters","reason":"page-shortening probe"}' \
  "${DAEMON_URL}/api/findings/${SIG}/ack" 2>/dev/null)"
if [ "${ACK_STATUS}" != "201" ] && [ "${ACK_STATUS}" != "200" ]; then
  fail "C.ack-screen" "could not ack a row to probe the short page (HTTP ${ACK_STATUS}), see ${TMP_DIR}/daemon.log"
  C_FAILED=1
else
  SHORT="$(rows "${DAEMON_URL}" "limit=10&offset=0")"
  NEXT="$(rows "${DAEMON_URL}" "limit=10&offset=10")"
  if [ "${SHORT}" -ne 9 ] || [ "${NEXT}" -eq 0 ]; then
    fail "C.ack-screen" "expected a 9-row first page and a non-empty second one, got ${SHORT} and ${NEXT}"
    C_FAILED=1
  fi
fi
# The counter-proof: 0.20.2 ignores `offset` and answers the whole listing.
BASE_OFFSET="$(rows "${BASELINE_URL}" "include_acked=true&limit=1000&offset=10")"
if [ "${BASE_OFFSET}" -ne "${BASE_TOTAL}" ]; then
  fail "C.counter-proof" "${BASELINE_IMAGE} honoured ?offset= (${BASE_OFFSET} of ${BASE_TOTAL}), so this leg proves nothing about 0.21.0"
  C_FAILED=1
fi
[ "${C_FAILED}" -eq 0 ] \
  && pass "C" "${TOTAL} rows walked ${PAGE} at a time reproduce the single read, past the end is empty, and the ack screen shortens a page that is not the last"

# --- D. the fold is unchanged ------------------------------------------------

step "D. the folded listing is what ${FOLD_BASELINE_IMAGE} returns"
# Read the reference with include_acked, and the side under test too: leg C
# left one ack behind on the local daemon and the comparison must not grade
# that. Both pages are the whole listing, so `offset` plays no part here,
# which is the point: what is compared is the fold, not the paging.
fetch "${FOLD_BASELINE_URL}" "include_acked=true&limit=1000" "${TMP_DIR}/fold-baseline.json"
fetch "${DAEMON_URL}" "include_acked=true&limit=1000" "${TMP_DIR}/fold-under-test.json"
if python3 "${FOLD}" compare "${TMP_DIR}/fold-baseline.json" "${TMP_DIR}/fold-under-test.json" \
     > "${TMP_DIR}/fold-diff.txt" 2>&1; then
  pass "D" "${TOTAL} rows identical to ${FOLD_BASELINE_IMAGE}: same batches in the same order (a batch split across two ticks merged back), same representative, same counts"
  sed 's/^/  note: /' "${TMP_DIR}/fold-diff.txt"
else
  fail "D" "the fold returns something the latest release does not, see ${TMP_DIR}/fold-diff.txt"
  head -12 "${TMP_DIR}/fold-diff.txt"
fi

# --- E. serialized_calls names the block -------------------------------------

step "E. the serialized_calls suggestion names the block instead of carrying it"
E_FAILED=0
python3 "${FIXTURE_GEN}" "${TMP_DIR}/serialized.json" "${SERIALIZED_CALLS}" "${SERIALIZED_TEMPLATE_BYTES}" >/dev/null \
  || die "could not build the serialized fixture"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${TMP_DIR}/serialized.json" --format json \
  > "${TMP_DIR}/serialized-under-test.json" 2>/dev/null \
  || die "analyze failed on the serialized fixture"
docker run --rm -v "${TMP_DIR}/serialized.json:/data/serialized.json:ro" "${BASELINE_IMAGE}" \
  analyze --input /data/serialized.json --format json \
  > "${TMP_DIR}/serialized-baseline.json" 2>/dev/null \
  || die "analyze failed on ${BASELINE_IMAGE}"
E_VERDICT="$(python3 - <<PY
import json, re, sys

def suggestion(path):
    report = json.load(open(path))
    rows = [f for f in report["findings"] if f["type"] == "serialized_calls"]
    if not rows:
        print("no serialized_calls finding in %s" % path)
        sys.exit(1)
    return rows[0]["suggestion"]

new = suggestion("${TMP_DIR}/serialized-under-test.json")
old = suggestion("${TMP_DIR}/serialized-baseline.json")
calls = ${SERIALIZED_CALLS}
problems = []
if len(new) > ${SUGGESTION_MAX_BYTES}:
    problems.append("the suggestion is %d bytes, above the %d bound"
                    % (len(new), ${SUGGESTION_MAX_BYTES}))
named = new.count(" -> ") - (1 if " -> ..." in new else 0) + 1
if named > 3:
    problems.append("%d templates named, at most 3 expected" % named)
if " -> ..." not in new:
    problems.append("no ' -> ...' elision for a block of %d calls" % calls)
# Each named call is "<template> (<N>ms)", the template cut at 120
# characters plus the three dots. Matched by splitting rather than by a
# regex over the whole sentence: a SQL template contains spaces and commas,
# so no character class delimits it.
cut = "." * 3
# The call list alone: the sentence opens with the count and closes with the
# totals, and splitting the whole of it counted the prose as two calls.
body = new.split("parallelized: ", 1)[-1].split(". Total sequential:", 1)[0]
named_calls = [c for c in body.split(" -> ") if c != cut]
lengths = []
for call in named_calls:
    body = re.sub(r" \(\d+ms\)$", "", call)
    lengths.append(len(body))
if not any(n == ${SUGGESTION_TEMPLATE_CHARS} + len(cut) and body.endswith(cut)
           for n, body in zip(lengths, [re.sub(r" \(\d+ms\)$", "", c) for c in named_calls])):
    problems.append("no template cut at ${SUGGESTION_TEMPLATE_CHARS} characters, lengths were %s" % lengths)
if any(n > ${SUGGESTION_TEMPLATE_CHARS} + len(cut) for n in lengths):
    problems.append("a template ran past the cut, lengths were %s" % lengths)
if not new.startswith("%d sequential" % calls):
    problems.append("the call count is no longer the block's own")
if not re.search(r"Total sequential: \d+ms, potential parallel: ~\d+ms", new):
    problems.append("the total and the parallel estimate are gone")
# The counter-proof, in the same breath: without it, a build that never
# produced a long sentence would pass this leg too.
if len(old) <= len(new) * 10:
    problems.append("the baseline suggestion is %d bytes, not the unbounded "
                    "sentence this leg exists to compare against" % len(old))
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("%d bytes against %d on the baseline, %d templates named, cut and elided"
      % (len(new), len(old), named))
PY
)"
if [ $? -ne 0 ]; then
  fail "E" "${E_VERDICT}"
  E_FAILED=1
else
  pass "E" "${E_VERDICT}"
fi

# --- summary -----------------------------------------------------------------

step "Summary"
VERDICT="PASS"; [ "${FAILURES}" -gt 0 ] && VERDICT="FAIL"
{
  echo "# perf-sentinel findings page filters"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Under test: ${VERSION} (${PRODUCT_COMMIT})"
  echo "Baseline:   ${BASELINE_IMAGE} (legs A, B, C, E)"
  echo "Fold:       ${FOLD_BASELINE_IMAGE} (leg D)"
  echo "Corpus:     ${TOTAL} folded rows over ${TENANT_A} and ${TENANT_B}"
  echo
  echo "| check | verdict | evidence |"
  echo "|---|---|---|"
  for row in "${RESULTS[@]}"; do
    IFS='|' read -r name verdict note <<<"${row}"
    printf '| %s | %s | %s |\n' "${name}" "${verdict}" "${note}"
  done
  echo
  echo "**Verdict: ${VERDICT}**"
} > "${REPORT}"

if [ "${VERDICT}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
fi
die "${FAILURES} findings-page assertion(s) failed, see ${REPORT}"
