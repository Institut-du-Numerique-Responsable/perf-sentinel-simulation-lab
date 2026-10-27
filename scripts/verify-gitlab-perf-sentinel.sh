#!/usr/bin/env bash
# End-to-end validation of the perf-sentinel GitLab CI template.
# Pushes a commit on main, then opens a merge request, and asserts:
#   - main pipeline ends in success (gate allow_failure on main)
#   - MR pipeline ends in failed (gate enforced on MR)
#   - SARIF + perf-sentinel-report.json + gl-code-quality-report.json
#     artefacts are present and well-formed
# Requires make up-gitlab + make seed-gitlab-project to have run.
# Usage: ./scripts/verify-gitlab-perf-sentinel.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

GITLAB_URL="http://localhost:8181"
ROOT_USER="root"
PROJECT_NAME="perf-sentinel-template-test"
PAT_FILE="/tmp/gitlab-pat.txt"
RESULTS_DIR="/tmp/gitlab-verify"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

[ -f "${PAT_FILE}" ] || die "${PAT_FILE} missing. Run make seed-gitlab-project first."
TOKEN="$(cat "${PAT_FILE}")"
mkdir -p "${RESULTS_DIR}"

api() {
  curl -fsS -H "Authorization: Bearer ${TOKEN}" "$@"
}

step "Resolving project id"
PROJECT_ID="$(api "${GITLAB_URL}/api/v4/projects?owned=true&search=${PROJECT_NAME}" \
  | python3 -c 'import json,sys
projects=json.load(sys.stdin)
match=[p for p in projects if p["path"]==sys.argv[1]]
print(match[0]["id"] if match else "")' "${PROJECT_NAME}")"
[ -n "${PROJECT_ID}" ] || die "project ${PROJECT_NAME} not found"
ok "project id ${PROJECT_ID}"

WORK_DIR="$(mktemp -d)"
ASKPASS_SCRIPT="$(mktemp)"
# Same askpass pattern as seed-gitlab-project.sh: keep the PAT out of
# the URL (and out of argv) by feeding it via env to git's askpass.
trap 'rm -rf "${WORK_DIR}"; rm -f "${ASKPASS_SCRIPT}"' EXIT
cat > "${ASKPASS_SCRIPT}" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  Username*) echo oauth2 ;;
  Password*) echo "${LAB_GIT_TOKEN}" ;;
esac
ASKPASS
chmod 700 "${ASKPASS_SCRIPT}"
export LAB_GIT_TOKEN="${TOKEN}"
export GIT_ASKPASS="${ASKPASS_SCRIPT}"

step "Cloning project to ${WORK_DIR}"
git clone -q "${GITLAB_URL}/${ROOT_USER}/${PROJECT_NAME}.git" "${WORK_DIR}"
cd "${WORK_DIR}"
git config user.email "lab-verify@example.com"
git config user.name "lab-verify"

wait_for_pipeline() {
  local sha="$1"
  local source_filter="${2:-}"
  local timeout_secs="${3:-600}"
  local query="${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/pipelines?sha=${sha}"
  if [ -n "${source_filter}" ]; then
    query="${query}&source=${source_filter}"
  fi
  local elapsed=0
  local pipeline_id=""
  while [ "${elapsed}" -lt "${timeout_secs}" ]; do
    pipeline_id="$(api "${query}" \
      | python3 -c 'import json,sys
pipes=json.load(sys.stdin)
print(pipes[0]["id"] if pipes else "")')"
    if [ -n "${pipeline_id}" ]; then
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  [ -n "${pipeline_id}" ] \
    || die "no ${source_filter:-any}-source pipeline picked up sha ${sha} within ${timeout_secs}s"

  local status=""
  while [ "${elapsed}" -lt "${timeout_secs}" ]; do
    status="$(api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/pipelines/${pipeline_id}" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])')"
    case "${status}" in
      success|failed|canceled|skipped) break ;;
    esac
    sleep 10
    elapsed=$((elapsed + 10))
  done
  printf '%s %s\n' "${pipeline_id}" "${status}"
}

job_for_name() {
  local pipeline_id="$1"
  local job_name="$2"
  api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/pipelines/${pipeline_id}/jobs" \
    | python3 -c '
import json,sys
target=sys.argv[1]
for j in json.load(sys.stdin):
    if j["name"]==target:
        print(j["id"])
        sys.exit(0)
' "${job_name}"
}

step "1. Push a commit on main and observe the pipeline"
# ci-e2e-gitlab pushes its own pipeline into this shared project. Put the
# seeded files back so this run tests the upstream template whatever ran
# before it.
FIXTURES_DIR="${REPO_ROOT}/artifacts/fixtures"
cp "${FIXTURES_DIR}/em-real-time-traces.json" test-traces.json
cp "${FIXTURES_DIR}/perf-sentinel-test.toml"  .perf-sentinel.toml
cp "${FIXTURES_DIR}/gitlab-ci-from-upstream.yml" .gitlab-ci.yml
echo "lab verify $(date -u +%FT%TZ)" >> README.md
git add README.md test-traces.json .perf-sentinel.toml .gitlab-ci.yml
git commit -q -m "verify: bump README"
git push -q origin HEAD:main
SHA_MAIN="$(git rev-parse HEAD)"
# Capture wait_for_pipeline output through a variable so the function's
# `set -e`-induced exit propagates with its own die() message instead of
# turning into a cryptic `read` failure on EOF. The source filter pins
# us to the push-event pipeline on main (the only one created for a
# direct push to the default branch).
MAIN_RESULT="$(wait_for_pipeline "${SHA_MAIN}" push)"
read -r MAIN_PIPELINE MAIN_STATUS <<< "${MAIN_RESULT}"
ok "main pipeline ${MAIN_PIPELINE} ended in ${MAIN_STATUS}"
[ "${MAIN_STATUS}" = "success" ] \
  || die "expected success on main (allow_failure: true), got ${MAIN_STATUS}"

step "  Downloading artefacts from main pipeline"
PERF_JOB_ID="$(job_for_name "${MAIN_PIPELINE}" "perf-sentinel")"
[ -n "${PERF_JOB_ID}" ] || die "perf-sentinel job not found in pipeline ${MAIN_PIPELINE}"
api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/jobs/${PERF_JOB_ID}/artifacts" \
  -o "${RESULTS_DIR}/main-artifacts.zip"
unzip -oq "${RESULTS_DIR}/main-artifacts.zip" -d "${RESULTS_DIR}/main"
[ -s "${RESULTS_DIR}/main/findings.sarif" ] || die "findings.sarif missing or empty"
python3 - "${RESULTS_DIR}/main/findings.sarif" <<'PY'
import json,sys
sarif=json.load(open(sys.argv[1]))
assert sarif.get("version")=="2.1.0", sarif.get("version")
runs=sarif.get("runs",[])
assert runs and runs[0]["tool"]["driver"]["name"]=="perf-sentinel"
print("    sarif ok, findings:", sum(len(r.get("results",[])) for r in runs))
PY
[ -s "${RESULTS_DIR}/main/perf-sentinel-report.json" ] || die "perf-sentinel-report.json missing"
python3 - "${RESULTS_DIR}/main/perf-sentinel-report.json" <<'PY'
import json,sys
rep=json.load(open(sys.argv[1]))
for k in ("findings","green_summary","quality_gate"):
    assert k in rep, k
print("    report ok, findings:", len(rep["findings"]))
PY

step "2. Push a fresh branch and open a merge request"
MR_BRANCH="feat/verify-mr-$(date -u +%Y%m%dT%H%M%SZ)"
git checkout -q -b "${MR_BRANCH}"
echo "mr verify $(date -u +%FT%TZ)" >> README.md
git add README.md
git commit -q -m "verify: trigger MR pipeline"
git push -q origin "HEAD:${MR_BRANCH}"
SHA_MR="$(git rev-parse HEAD)"
api -X POST "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/merge_requests" \
  -H "Content-Type: application/json" \
  -d "$(printf '{"source_branch":"%s","target_branch":"main","title":"verify: MR pipeline"}' "${MR_BRANCH}")" \
  > "${RESULTS_DIR}/mr.json"
# Pin the wait to the merge_request_event pipeline so the verify
# observes the gate-enforced run. GitLab also creates a push-event
# pipeline on the source branch in parallel. That one would skip the
# perf-sentinel job on its own rules and report success even when the
# gate is breached.
MR_RESULT="$(wait_for_pipeline "${SHA_MR}" merge_request_event)"
read -r MR_PIPELINE MR_STATUS <<< "${MR_RESULT}"
ok "MR pipeline ${MR_PIPELINE} ended in ${MR_STATUS}"
[ "${MR_STATUS}" = "failed" ] \
  || die "expected failed on MR (allow_failure: false), got ${MR_STATUS}"

step "  Downloading artefacts from MR pipeline (when: always)"
PERF_JOB_ID_MR="$(job_for_name "${MR_PIPELINE}" "perf-sentinel")"
api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/jobs/${PERF_JOB_ID_MR}/artifacts" \
  -o "${RESULTS_DIR}/mr-artifacts.zip"
unzip -oq "${RESULTS_DIR}/mr-artifacts.zip" -d "${RESULTS_DIR}/mr"
[ -s "${RESULTS_DIR}/mr/findings.sarif" ] \
  || die "SARIF missing on MR pipeline (artifact when: always not honored)"

# The Code Quality JSON is uploaded as a `reports.codequality` artifact,
# not a path artifact, so it is not in the downloadable zip. Verify the
# upload by inspecting the job's artifacts metadata: a `file_type:
# codequality` entry proves the report was accepted by the GitLab UI.
api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/jobs/${PERF_JOB_ID_MR}" \
  > "${RESULTS_DIR}/mr/job-meta.json"
python3 - "${RESULTS_DIR}/mr/job-meta.json" <<'PY'
import json,sys
meta=json.load(open(sys.argv[1]))
arts=meta.get("artifacts",[])
cq=[a for a in arts if a.get("file_type")=="codequality"]
assert cq, "codequality artifact missing from job metadata"
size=cq[0]["size"]
assert size>0, "codequality artifact has zero size"
print(f"    code quality ok, {size} bytes uploaded as reports.codequality")
PY

step "Cleaning up the MR branch on the server"
# Encode the slash in feat/verify-mr-* so the branch deletion API
# accepts it. Best-effort: a leftover branch would only show up as
# noise in the project, not a functional issue.
ENCODED_BRANCH="$(printf '%s' "${MR_BRANCH}" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')"
api -X DELETE \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/branches/${ENCODED_BRANCH}" \
  >/dev/null 2>&1 || color_red "    warn: failed to delete ${MR_BRANCH} on the remote (non-fatal)"

step "Summary"
color_green "  main pipeline (${MAIN_PIPELINE}): ${MAIN_STATUS}"
color_green "  MR pipeline   (${MR_PIPELINE}):   ${MR_STATUS}"
color_green "  artefacts:    ${RESULTS_DIR}/{main,mr}/"
color_green ""
color_green "Quality gate behavior: success on main (allow_failure: true)"
color_green "                       failed on MR  (allow_failure: false)"
color_green "End-to-end validation: PASS"
