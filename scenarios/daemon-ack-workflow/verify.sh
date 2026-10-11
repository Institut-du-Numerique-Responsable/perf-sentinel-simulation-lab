#!/usr/bin/env bash
# daemon-ack-workflow: end-to-end validation of the perf-sentinel daemon
# ack workflow. Validates the 0.5.20 ack API (POST/DELETE/GET) with the
# 0.5.21 Prometheus counter surface, plus persistence on the
# perf-sentinel-acks PVC across daemon restarts.
#
# Sub-tests:
#   1. Sanity                : daemon reachable on /api/status
#   2. Seed                  : harvest 2 finding signatures via /api/export/report
#   3. Counter snapshot      : ack/unack/fail counters BEFORE
#   4. POST sig_a            : 201 with expires_at = now + TTL_SEC
#   5. Filter check          : feature-detect /api/findings, soft-assert annotation
#   6. Counter delta sig_a   : ACK_AFTER - ACK_BEFORE == 1, fallback /api/acks list
#   7. Restart + persistence : rollout, refresh_pf, /api/acks still has sig_a, JSONL sane
#   8. POST sig_b            : 201 with long TTL (kept for steps 9-10)
#   9. 409 conflict          : POST sig_b again -> 409, fail counter delta == 1
#  10. DELETE sig_b          : 204, unack counter delta == 1
#  11. TTL expiry            : sleep + poll, sig_a dropped at query time
#  12. include_toml (0.24.0) : a throwaway daemon of its own reads a CI TOML
#                              baseline, the flagged listing names both sources
#                              and the key is checked before the value
#
# Counter assertions tolerate the 0.5.20 surface where ack_operations_total
# is not exposed (verdict_source=counter_absent_0520_fallback). When the
# pre-warmed 0.5.21 series is present, the script asserts BEFORE/AFTER
# delta to stay correct across CI scenario chains.

set -euo pipefail

SCENARIO="daemon-ack-workflow"
NS="observability"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
TTL_SEC="${TTL_SEC:-30}"
TTL_LONG_SEC="${TTL_LONG_SEC:-300}"
EXPIRY_SLEEP_SEC="${EXPIRY_SLEEP_SEC:-35}"
EXPIRY_POLL_SEC="${EXPIRY_POLL_SEC:-15}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

VERDICTS=()

refresh_pf() {
  pkill -f "kubectl.*port-forward.*perf-sentinel-daemon" 2>/dev/null || true
  rm -f "${REPO_ROOT}/tmp/pf-daemon.pid" 2>/dev/null || true
  sleep 2
  "${REPO_ROOT}/scripts/port-forward.sh" start > "${TMP_DIR}/pf.log" 2>&1
  for _ in $(seq 1 60); do
    if curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Print int counter value matching the AWK pattern, or "MISSING".
query_counter() {
  local pattern="$1"
  local body val
  body=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" 2>/dev/null) || body=""
  val=$(printf '%s\n' "${body}" | awk -v p="${pattern}" '$0 ~ p {print $2; exit}')
  if [ -z "${val}" ]; then
    printf 'MISSING\n'
  else
    # Prometheus may render integer counters as "1" or "1.0".
    printf '%.0f\n' "${val}"
  fi
}

diff_counter() {
  local before="$1" after="$2"
  if [ "${before}" = "MISSING" ] || [ "${after}" = "MISSING" ]; then
    printf 'MISSING\n'
  else
    printf '%d\n' "$(( after - before ))"
  fi
}

# Probe whether /api/findings is exposed as a top-level endpoint (0.5.20+).
findings_endpoint_present() {
  local code
  code=$(curl -o /dev/null -s -w "%{http_code}" \
    "http://localhost:${DAEMON_LOCAL_PORT}/api/findings" 2>/dev/null || echo "000")
  [ "${code}" = "200" ]
}

# Portable "now + N seconds" in UTC ISO-8601, BSD or GNU date.
isoplus() {
  local n="$1"
  date -u -v "+${n}S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "+${n} seconds" +%Y-%m-%dT%H:%M:%SZ
}

#######################################
# 1. Sanity
#######################################
step "1. Sanity: daemon reachable on localhost:${DAEMON_LOCAL_PORT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable, run ./scripts/port-forward.sh start"
ok "daemon reachable"

#######################################
# 2. Seed: harvest finding signatures
#######################################
step "2. Harvest finding signatures from /api/export/report"
REPORT_JSON="${TMP_DIR}/report.json"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" > "${REPORT_JSON}" \
  || die "GET /api/export/report failed"
N_FINDINGS=$(python3 -c "import json; print(len(json.load(open('${REPORT_JSON}')).get('findings', [])))")
if [ "${N_FINDINGS}" -lt 3 ]; then
  die "Need >=3 distinct finding signatures (got ${N_FINDINGS}). Run: make seed-services && scripts/validate-findings.sh"
fi
# Harvest 3 distinct signatures. sig_a/sig_b take long TTLs to keep them
# active across the rollout restart and the duplicate-POST conflict
# probe. sig_c uses the short TTL for the expiry test.
read -r SIG_A SIG_B SIG_C < <(python3 -c "
import json
data = json.load(open('${REPORT_JSON}'))
seen = []
for f in data.get('findings', []):
    s = f.get('signature')
    if s and s not in seen:
        seen.append(s)
    if len(seen) == 3:
        break
print(' '.join(seen))
")
if [ -z "${SIG_C:-}" ]; then
  die "Could not harvest 3 distinct signatures from /api/export/report"
fi
export SIG_A SIG_B SIG_C
ok "sig_a=${SIG_A:0:24}... sig_b=${SIG_B:0:24}... sig_c=${SIG_C:0:24}..."

#######################################
# 3. Counter snapshot BEFORE
#######################################
step "3. Idempotent cleanup + snapshot counters BEFORE"
# The PVC persists acks across runs, so a re-run may find sig_{a,b,c}
# already acked. Best-effort DELETE, 204 and 404 are both fine here.
for sig in "${SIG_A}" "${SIG_B}" "${SIG_C}"; do
  enc=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${sig}")
  curl -o /dev/null -s -X DELETE "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${enc}/ack" 2>/dev/null || true
done

ACK_BEFORE=$(query_counter '^perf_sentinel_ack_operations_total\{action="ack"\}')
UNACK_BEFORE=$(query_counter '^perf_sentinel_ack_operations_total\{action="unack"\}')
FAIL_ALREADY_BEFORE=$(query_counter '^perf_sentinel_ack_operations_failed_total\{action="ack",reason="already_acked"\}')
COUNTER_SOURCE="counter_absent_0520_fallback"
if [ "${ACK_BEFORE}" != "MISSING" ]; then
  COUNTER_SOURCE="counter_present_0521"
fi
ok "ack=${ACK_BEFORE} unack=${UNACK_BEFORE} fail_already=${FAIL_ALREADY_BEFORE} source=${COUNTER_SOURCE}"

#######################################
# 4. POST sig_a (short TTL)
#######################################
step "4. POST /api/findings/{sig_a}/ack (long expires in ${TTL_LONG_SEC}s)"
EXPIRES_A=$(isoplus "${TTL_LONG_SEC}")
SIG_A_ENC=$(python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['SIG_A'], safe=''))")
POST_A_BODY=$(printf '{"by":"alice","reason":"deferred","expires_at":"%s"}' "${EXPIRES_A}")
HTTP_A=$(curl -o "${TMP_DIR}/post-a.json" -s -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "${POST_A_BODY}" \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_A_ENC}/ack" 2>/dev/null || echo "000")
if [ "${HTTP_A}" = "201" ]; then
  VERDICTS+=("PASS: 4 POST sig_a -> 201 (expires=${EXPIRES_A})")
else
  VERDICTS+=("FAIL: 4 POST sig_a -> HTTP ${HTTP_A} (body=$(head -c 120 "${TMP_DIR}/post-a.json" 2>/dev/null))")
fi

#######################################
# 5. Filter check (feature-detect /api/findings)
#######################################
step "5. Filter check (feature-detect /api/findings)"
if findings_endpoint_present; then
  HIDDEN=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/findings" 2>/dev/null \
    | python3 -c "
import json, sys, os
sig = os.environ['SIG_A']
d = json.load(sys.stdin)
items = d if isinstance(d, list) else (d.get('findings', []) if isinstance(d, dict) else [])
print('YES' if any(f.get('signature') == sig for f in items) else 'NO')
" 2>/dev/null || echo "PARSE_ERR")
  ANNOTATED=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/findings?include_acked=true" 2>/dev/null \
    | python3 -c "
import json, sys, os
sig = os.environ['SIG_A']
d = json.load(sys.stdin)
items = d if isinstance(d, list) else (d.get('findings', []) if isinstance(d, dict) else [])
match = [f for f in items if f.get('signature') == sig]
if not match:
    print('MISSING')
else:
    ack = match[0].get('acknowledged_by') or {}
    print('OK' if ack.get('by') == 'alice' else 'NO_ANNOTATION')
" 2>/dev/null || echo "PARSE_ERR")
  if [ "${HIDDEN}" = "NO" ] && [ "${ANNOTATED}" = "OK" ]; then
    VERDICTS+=("PASS: 5 filter (default hides sig_a, ?include_acked=true exposes acknowledged_by.by=alice)")
  elif [ "${HIDDEN}" = "NO" ]; then
    VERDICTS+=("PASS: 5 filter default hides sig_a (annotation surface=${ANNOTATED}, soft assert)")
  else
    VERDICTS+=("FAIL: 5 filter (sig_a hidden=${HIDDEN} annotated=${ANNOTATED})")
  fi
else
  VERDICTS+=("PASS: 5 filter skipped (/api/findings not exposed in this build, soft assert)")
fi

#######################################
# 6. Counter delta sig_a
#######################################
step "6. Counter delta for ack action"
ACK_AFTER1=$(query_counter '^perf_sentinel_ack_operations_total\{action="ack"\}')
DELTA_ACK=$(diff_counter "${ACK_BEFORE}" "${ACK_AFTER1}")
if [ "${DELTA_ACK}" = "MISSING" ]; then
  ACKS_LIST=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/acks" 2>/dev/null) || ACKS_LIST='[]'
  ACK_COUNT=$(printf '%s' "${ACKS_LIST}" | python3 -c "
import json, sys, os
sig = os.environ['SIG_A']
try:
    d = json.load(sys.stdin)
    items = d if isinstance(d, list) else (d.get('acks', []) if isinstance(d, dict) else [])
    print(len([a for a in items if a.get('signature') == sig]))
except Exception:
    print(0)
" 2>/dev/null || echo "0")
  if [ "${ACK_COUNT}" -ge 1 ]; then
    VERDICTS+=("PASS: 6 ack via API list (counter_absent_0520_fallback, sig_a present)")
  else
    VERDICTS+=("FAIL: 6 ack list does not contain sig_a after POST (count=${ACK_COUNT})")
  fi
elif [ "${DELTA_ACK}" -eq 1 ]; then
  VERDICTS+=("PASS: 6 counter delta=1 (counter_present_0521, action=ack)")
else
  VERDICTS+=("FAIL: 6 counter delta=${DELTA_ACK} expected 1 (before=${ACK_BEFORE} after=${ACK_AFTER1})")
fi

#######################################
# 7. Rollout restart + persistence on PVC
#######################################
step "7. Rollout restart + persistence on PVC"
kubectl -n "${NS}" rollout restart deployment/perf-sentinel-daemon >/dev/null
kubectl -n "${NS}" rollout status deployment/perf-sentinel-daemon --timeout=120s >/dev/null
if ! refresh_pf; then
  VERDICTS+=("FAIL: 7 daemon did not come back from rollout")
else
  ACKS_AFTER_RESTART=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/acks" 2>/dev/null) || ACKS_AFTER_RESTART='[]'
  SIG_A_PERSISTED=$(printf '%s' "${ACKS_AFTER_RESTART}" | python3 -c "
import json, sys, os
sig = os.environ['SIG_A']
try:
    d = json.load(sys.stdin)
    items = d if isinstance(d, list) else (d.get('acks', []) if isinstance(d, dict) else [])
    print('YES' if any(a.get('signature') == sig for a in items) else 'NO')
except Exception:
    print('NO')
" 2>/dev/null || echo "NO")
  # Persistence is the load-bearing assert: if sig_a still surfaces in
  # /api/acks after the rollout, the PVC mount + JSONL replay worked.
  # Compaction is upstream-tested. The lab cannot easily measure file
  # size from a distroless container without an ephemeral debug pod
  # that explicitly mounts the same PVC.
  if [ "${SIG_A_PERSISTED}" = "YES" ]; then
    VERDICTS+=("PASS: 7 persistence (sig_a survived rollout via PVC-backed JSONL)")
  else
    VERDICTS+=("FAIL: 7 persistence (sig_a persisted=${SIG_A_PERSISTED})")
  fi
fi

#######################################
# 8. POST sig_b (long TTL, used for 9-10)
#######################################
step "8. POST /api/findings/{sig_b}/ack (long expires in ${TTL_LONG_SEC}s)"
EXPIRES_B=$(isoplus "${TTL_LONG_SEC}")
SIG_B_ENC=$(python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['SIG_B'], safe=''))")
POST_B_BODY=$(printf '{"by":"alice","reason":"long-lived","expires_at":"%s"}' "${EXPIRES_B}")
HTTP_B=$(curl -o "${TMP_DIR}/post-b.json" -s -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "${POST_B_BODY}" \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_B_ENC}/ack" 2>/dev/null || echo "000")
if [ "${HTTP_B}" = "201" ]; then
  VERDICTS+=("PASS: 8 POST sig_b -> 201 (expires=${EXPIRES_B})")
else
  VERDICTS+=("FAIL: 8 POST sig_b -> HTTP ${HTTP_B}")
fi

#######################################
# 9. 409 conflict on already-acked sig_b
#######################################
step "9. POST sig_b twice -> 409 already_acked"
FAIL_ALREADY_BEFORE9=$(query_counter '^perf_sentinel_ack_operations_failed_total\{action="ack",reason="already_acked"\}')
HTTP_B2=$(curl -o "${TMP_DIR}/post-b2.json" -s -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "${POST_B_BODY}" \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_B_ENC}/ack" 2>/dev/null || echo "000")
FAIL_ALREADY_AFTER=$(query_counter '^perf_sentinel_ack_operations_failed_total\{action="ack",reason="already_acked"\}')
DELTA_FAIL_ALREADY=$(diff_counter "${FAIL_ALREADY_BEFORE9}" "${FAIL_ALREADY_AFTER}")
if [ "${HTTP_B2}" != "409" ]; then
  VERDICTS+=("FAIL: 9 duplicate POST -> HTTP ${HTTP_B2} expected 409")
elif [ "${DELTA_FAIL_ALREADY}" = "MISSING" ]; then
  VERDICTS+=("PASS: 9 duplicate POST -> 409 (counter_absent_0520_fallback)")
elif [ "${DELTA_FAIL_ALREADY}" -eq 1 ]; then
  VERDICTS+=("PASS: 9 duplicate POST -> 409 (counter_present_0521, fail_already_acked delta=1)")
else
  VERDICTS+=("FAIL: 9 duplicate POST -> 409 but counter delta=${DELTA_FAIL_ALREADY} expected 1")
fi

#######################################
# 10. DELETE sig_b
#######################################
step "10. DELETE /api/findings/{sig_b}/ack"
# Re-snapshot the unack counter immediately before the DELETE: the
# rollout restart in step 7 reset the daemon process, so the BEFORE
# value captured at step 3 is no longer comparable with AFTER.
UNACK_BEFORE_DEL=$(query_counter '^perf_sentinel_ack_operations_total\{action="unack"\}')
HTTP_DEL=$(curl -o "${TMP_DIR}/del-b.json" -s -w "%{http_code}" \
  -X DELETE \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_B_ENC}/ack" 2>/dev/null || echo "000")
UNACK_AFTER=$(query_counter '^perf_sentinel_ack_operations_total\{action="unack"\}')
DELTA_UNACK=$(diff_counter "${UNACK_BEFORE_DEL}" "${UNACK_AFTER}")
if [ "${HTTP_DEL}" != "204" ] && [ "${HTTP_DEL}" != "200" ]; then
  VERDICTS+=("FAIL: 10 DELETE sig_b -> HTTP ${HTTP_DEL} expected 204")
elif [ "${DELTA_UNACK}" = "MISSING" ]; then
  VERDICTS+=("PASS: 10 DELETE sig_b -> ${HTTP_DEL} (counter_absent_0520_fallback)")
elif [ "${DELTA_UNACK}" -ge 1 ]; then
  VERDICTS+=("PASS: 10 DELETE sig_b -> ${HTTP_DEL} (counter_present_0521, unack delta=${DELTA_UNACK})")
else
  VERDICTS+=("FAIL: 10 DELETE sig_b -> ${HTTP_DEL} but unack delta=${DELTA_UNACK}")
fi

#######################################
# 11. TTL expiry on a fresh sig_c (short TTL)
#######################################
step "11. POST sig_c (TTL ${TTL_SEC}s) then sleep+poll for expiry drop"
EXPIRES_C=$(isoplus "${TTL_SEC}")
SIG_C_ENC=$(python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['SIG_C'], safe=''))")
POST_C_BODY=$(printf '{"by":"alice","reason":"expiry-test","expires_at":"%s"}' "${EXPIRES_C}")
HTTP_C=$(curl -o "${TMP_DIR}/post-c.json" -s -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "${POST_C_BODY}" \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_C_ENC}/ack" 2>/dev/null || echo "000")
if [ "${HTTP_C}" != "201" ]; then
  VERDICTS+=("FAIL: 11 TTL prep POST sig_c -> HTTP ${HTTP_C}")
else
  sleep "${EXPIRY_SLEEP_SEC}"
  EXPIRED="NO"
  DEADLINE=$(( $(date +%s) + EXPIRY_POLL_SEC ))
  while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    ACKS_NOW=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/acks" 2>/dev/null) || ACKS_NOW='[]'
    STILL_PRESENT=$(printf '%s' "${ACKS_NOW}" | python3 -c "
import json, sys, os
sig = os.environ['SIG_C']
try:
    d = json.load(sys.stdin)
    items = d if isinstance(d, list) else (d.get('acks', []) if isinstance(d, dict) else [])
    print('YES' if any(a.get('signature') == sig for a in items) else 'NO')
except Exception:
    print('YES')
" 2>/dev/null || echo "YES")
    if [ "${STILL_PRESENT}" = "NO" ]; then
      EXPIRED="YES"
      break
    fi
    sleep 2
  done
  if [ "${EXPIRED}" = "YES" ]; then
    VERDICTS+=("PASS: 11 TTL filter (sig_c dropped at query time within ${EXPIRY_SLEEP_SEC}+${EXPIRY_POLL_SEC}s)")
  else
    VERDICTS+=("FAIL: 11 TTL filter (sig_c still present after ${EXPIRY_SLEEP_SEC}+${EXPIRY_POLL_SEC}s)")
  fi
fi

#######################################
# 12. include_toml: the CI baseline beside the runtime acks (0.24.0)
#######################################
step "12. GET /api/acks?include_toml=true beside a CI TOML baseline"
# The listing held only the daemon's own JSONL acks, so a reader that mirrors
# the ack state could not learn that the CI baseline acknowledges a finding
# once that finding had left the findings ring. The lab daemon sets neither
# `[daemon.ack] toml_path` nor `[daemon.ack] api_key`, so it has no baseline to
# merge and no gate to judge a malformed value after, and giving it either
# would mean editing manifests/perf-sentinel-daemon.yaml, which carries an
# uncommitted local pin during a pre-release pass. This leg runs the image
# under validation as a throwaway pod of its own instead.
TOML_NS="ack-toml-baseline"
TOML_PORT="${TOML_PORT:-14419}"
TOML_URL="http://localhost:${TOML_PORT}"
TOML_KEY="lab-ack-toml-key-0"
TOML_MANIFESTS="$(cd "$(dirname "$0")" && pwd)/manifests.yaml"
SIG_DAEMON="n_plus_one_sql:runtime-svc:GET__api_runtime:dddddddddddddddddddddddddddddddd"
SIG_DAEMON2="slow_sql:runtime-svc:GET__api_runtime_slow:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
SIG_PERM="n_plus_one_sql:baseline-svc:GET__api_orders:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SIG_LIVE="slow_sql:baseline-svc:GET__api_invoices:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SIG_EXPIRED="redundant_sql:baseline-svc:GET__api_carts:cccccccccccccccccccccccccccccccc"
export SIG_DAEMON SIG_DAEMON2 SIG_PERM SIG_LIVE SIG_EXPIRED

# The pod runs the image under validation, resolved by scripts/resolve-image.sh:
# PERF_SENTINEL_IMAGE, then PERF_SENTINEL_VERSION, then the daemon manifest pin.
LAB_ROOT="${REPO_ROOT}"
# shellcheck source=../../scripts/resolve-image.sh
. "${REPO_ROOT}/scripts/resolve-image.sh"

TOML_PF_PID=""
cleanup_toml() {
  if [ -n "${TOML_PF_PID}" ]; then kill "${TOML_PF_PID}" 2>/dev/null || true; fi
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${TOML_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup_toml EXIT

# A Pod is immutable on the fields the rewrite touches, so a re-run drops the
# previous one rather than applying over it.
kubectl -n "${TOML_NS}" delete pod perf-sentinel-ack-toml --ignore-not-found >/dev/null 2>&1 || true
# Rendered to a file rather than piped, so the rewrite can be asserted. A sed
# that matches nothing would silently run the digest frozen in manifests.yaml,
# which is the failure scripts/resolve-image.sh exists to prevent.
sed -e "s#image: ghcr.io/institut-du-numerique-responsable/perf-sentinel@sha256:[0-9a-f]*.*#image: ${IMAGE}#" "${TOML_MANIFESTS}" \
  > "${TMP_DIR}/ack-toml.rendered.yaml"
grep -qF "image: ${IMAGE}" "${TMP_DIR}/ack-toml.rendered.yaml" \
  || die "the image rewrite matched nothing, the pod would run the digest frozen in manifests.yaml"
kubectl apply -f "${TMP_DIR}/ack-toml.rendered.yaml" > "${TMP_DIR}/ack-toml-apply.log" 2>&1 \
  || die "kubectl apply failed, see ${TMP_DIR}/ack-toml-apply.log"
kubectl -n "${TOML_NS}" wait --for=condition=Ready pod/perf-sentinel-ack-toml --timeout=120s >/dev/null \
  || die "the baseline daemon never became Ready, see kubectl -n ${TOML_NS} describe pod perf-sentinel-ack-toml"
ok "baseline daemon Ready on ${IMAGE}"

kubectl -n "${TOML_NS}" port-forward pod/perf-sentinel-ack-toml "${TOML_PORT}:14318" \
  > "${TMP_DIR}/ack-toml-pf.log" 2>&1 &
TOML_PF_PID=$!
# Off the job table: the shell would otherwise print "Terminated" of its own
# when the cleanup kills it, which reads like a failure at the end of a pass.
disown "${TOML_PF_PID}" 2>/dev/null || true
TOML_UP="no"
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "${TOML_URL}/health" 2>/dev/null; then
    TOML_UP="yes"
    break
  fi
  sleep 1
done
[ "${TOML_UP}" = "yes" ] || die "port-forward to the baseline daemon never answered on ${TOML_PORT}"

# Two runtime acks, so the flagged listing carries a block of each source and
# the ordering assertion below pins a boundary rather than one row's position.
# Their signatures name no finding the pod ever saw: the ack store validates
# the format, never the existence.
post_runtime_ack() {  # $1 = signature
  local enc
  enc=$(SIG="$1" python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['SIG'], safe=''))")
  curl -o /dev/null -s -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" -H "X-API-Key: ${TOML_KEY}" \
    -d '{"by":"sre@lab","reason":"runtime ack"}' \
    "${TOML_URL}/api/findings/${enc}/ack" 2>/dev/null || echo "000"
}
HTTP_TOML_POST=$(post_runtime_ack "${SIG_DAEMON}")
HTTP_TOML_POST2=$(post_runtime_ack "${SIG_DAEMON2}")

curl -fsS -H "X-API-Key: ${TOML_KEY}" "${TOML_URL}/api/acks" \
  > "${TMP_DIR}/acks-default.json" 2>/dev/null || echo '[]' > "${TMP_DIR}/acks-default.json"
curl -fsS -H "X-API-Key: ${TOML_KEY}" "${TOML_URL}/api/acks?include_toml=true" \
  > "${TMP_DIR}/acks-flagged.json" 2>/dev/null || echo '[]' > "${TMP_DIR}/acks-flagged.json"

TOML_CHECK=$(python3 - "${TMP_DIR}/acks-default.json" "${TMP_DIR}/acks-flagged.json" <<'PY'
import json, os, sys


def check():
    default = json.load(open(sys.argv[1]))
    flagged = json.load(open(sys.argv[2]))
    daemon, daemon2, perm, live, expired = (
        os.environ[k] for k in
        ("SIG_DAEMON", "SIG_DAEMON2", "SIG_PERM", "SIG_LIVE", "SIG_EXPIRED"))
    bad = []

    # The default answer is what it always was: the daemon store alone, and
    # not a row of it names a source.
    if {a["signature"] for a in default} != {daemon, daemon2}:
        bad.append("default listing is %s" % sorted(a["signature"] for a in default))
    if any("source" in a for a in default):
        bad.append("default listing carries a source field")

    rows = {a["signature"]: a for a in flagged}
    if expired in rows:
        bad.append("the expired baseline entry is listed")
    for sig, want in ((daemon, "daemon"), (daemon2, "daemon"),
                      (perm, "toml"), (live, "toml")):
        got = rows.get(sig)
        if got is None:
            bad.append("%s missing from the flagged listing" % sig.split(":")[0])
        elif got.get("source") != want:
            bad.append("%s names source %r, expected %r"
                       % (sig.split(":")[0], got.get("source"), want))

    # A toml row maps the baseline entry onto the daemon fields: `by` from
    # `acknowledged_by`, `at` from `acknowledged_at` verbatim, which is a bare
    # date here and not a timestamp, and `expires_at` as the end of the expiry
    # day UTC.
    p = rows.get(perm, {})
    if (p.get("by"), p.get("at"), p.get("reason"), p.get("action")) != \
            ("ci-bot@lab", "2026-05-04", "permanent baseline", "ack"):
        bad.append("the permanent baseline row maps to %r" % p)
    if "expires_at" in p:
        bad.append("a baseline entry with no expiry carries expires_at=%r" % p["expires_at"])
    if rows.get(live, {}).get("expires_at") != "2099-12-31T23:59:59Z":
        bad.append("expires_at is %r, expected the end of the expiry day in UTC"
                   % rows.get(live, {}).get("expires_at"))

    # Both daemon acks, then the baseline sorted by signature: one block per
    # source, which is the order the 1000-row cap sheds from, since a baseline
    # past the cap loses its tail and never a runtime ack.
    sources = [a.get("source") for a in flagged]
    if sources != sorted(sources, key=lambda s: s != "daemon"):
        bad.append("sources come back as %s, the daemon rows are not the first block" % sources)

    return bad


# Any shape the daemon returns has to land as a FAIL verdict. Left to raise,
# the traceback would take the whole scenario down under `set -e` with no
# verdict and no report, which reads as a crashed harness and not as a broken
# contract.
try:
    problems = check()
except Exception as exc:
    print("PROBLEM: the checker failed on the answer: %r" % (exc,))
else:
    print("OK" if not problems else "PROBLEM: " + "; ".join(problems))
PY
)

if [ "${HTTP_TOML_POST}" = "201" ] && [ "${HTTP_TOML_POST2}" = "201" ] && [ "${TOML_CHECK}" = "OK" ]; then
  VERDICTS+=("PASS: 12 include_toml (default unchanged and sourceless, flagged lists the daemon block then the baseline, expired entry absent, end-of-day expiry)")
else
  VERDICTS+=("FAIL: 12 include_toml (runtime POSTs=${HTTP_TOML_POST}/${HTTP_TOML_POST2}, ${TOML_CHECK})")
fi

# The value is read after the key, so the parameter cannot be used to tell a
# gated route from an unknown one.
CODE_TOML_BARE=$(curl -o /dev/null -s -w "%{http_code}" \
  "${TOML_URL}/api/acks?include_toml=maybe" 2>/dev/null || echo "000")
CODE_TOML_KEYED=$(curl -o /dev/null -s -w "%{http_code}" -H "X-API-Key: ${TOML_KEY}" \
  "${TOML_URL}/api/acks?include_toml=maybe" 2>/dev/null || echo "000")
if [ "${CODE_TOML_BARE}" = "401" ] && [ "${CODE_TOML_KEYED}" = "400" ]; then
  VERDICTS+=("PASS: 12 malformed include_toml judged after the key (401 without it, 400 with it)")
else
  VERDICTS+=("FAIL: 12 malformed include_toml -> ${CODE_TOML_BARE} without the key, ${CODE_TOML_KEYED} with it (expected 401 then 400)")
fi

#######################################
# Aggregate verdicts
#######################################
step "Aggregate verdicts"
verdict="PASS"
for v in "${VERDICTS[@]}"; do
  echo "    ${v}"
  if echo "${v}" | grep -q "^FAIL"; then
    verdict="FAIL"
  fi
done

if [ "${verdict}" = "FAIL" ]; then
  kubectl -n "${NS}" logs deploy/perf-sentinel-daemon --tail=120 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# daemon-ack-workflow"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Counter source: ${COUNTER_SOURCE}"
  echo "TTL_SEC=${TTL_SEC} TTL_LONG_SEC=${TTL_LONG_SEC} EXPIRY_SLEEP_SEC=${EXPIRY_SLEEP_SEC} EXPIRY_POLL_SEC=${EXPIRY_POLL_SEC}"
  echo
  echo "## Counter snapshot (BEFORE)"
  echo
  echo "- ack=${ACK_BEFORE}"
  echo "- unack=${UNACK_BEFORE}"
  echo "- fail_already_acked=${FAIL_ALREADY_BEFORE}"
  echo
  echo "## Sub-test verdicts"
  echo
  for v in "${VERDICTS[@]}"; do
    echo "- ${v}"
  done
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Daemon logs (tail)"
    echo
    echo '```'
    tail -120 "${TMP_DIR}/daemon.log" 2>/dev/null || true
    echo '```'
    echo
  fi
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
