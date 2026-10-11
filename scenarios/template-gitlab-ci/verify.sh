#!/usr/bin/env bash
# Validate the upstream gitlab-ci.yml template at v0.13.1 end-to-end.
#
# 4 steps:
#
# 1. Curl the upstream `docs/ci-templates/gitlab-ci.yml` at v0.13.1
#    (override via UPSTREAM_VERSION).
# 2. Lint the template via the GitLab CE CI Lint API
#    (POST /api/v4/ci/lint). Asserts the YAML parses and the gitlab-ci
#    schema is satisfied.
# 3. Parity check between upstream and the lab fixture
#    `artifacts/fixtures/gitlab-ci-from-upstream.yml`. The lab fixture
#    pins an older version (0.5.14 historically) and adds a dummy
#    integration-tests job; check that the structural skeleton (stages,
#    job names, key directives) still matches.
# 4. Delegate to the existing verify-gitlab-perf-sentinel.sh which
#    already exercises the full GitLab pipeline against the in-cluster
#    GitLab CE. Surfaces its verdict.
#
# Optional knobs:
#   UPSTREAM_VERSION    override the version tag (default 0.13.1).
#   UPSTREAM_PATH       override with a local copy of the template
#                       (default fetches via curl).
#   SKIP_E2E=1          skip step 4 (faster, lint+parity only).

set -euo pipefail

SCENARIO="template-gitlab-ci"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
LAB_FIXTURE="${LAB_ROOT}/artifacts/fixtures/gitlab-ci-from-upstream.yml"
GITLAB_VERIFY="${LAB_ROOT}/scripts/verify-gitlab-perf-sentinel.sh"

# The tag whose template is fetched, derived from the fixture's own pin so a
# bump happens in one place. Both have to name a PUBLISHED release: the seeded
# pipeline downloads that release binary from GitHub, and step 3 fails when the
# two disagree. It sat on 0.13.1 here against 0.5.17 in the fixture, and nothing
# compared them.
FIXTURE_PIN="$(grep -oE 'PERF_SENTINEL_VERSION:[[:space:]]*"[0-9.]+"' "${LAB_FIXTURE}" \
  | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
UPSTREAM_VERSION="${UPSTREAM_VERSION:-${FIXTURE_PIN:-0.22.2}}"
UPSTREAM_URL="https://raw.githubusercontent.com/Institut-du-Numerique-Responsable/perf-sentinel/v${UPSTREAM_VERSION}/docs/ci-templates/gitlab-ci.yml"
GITLAB_URL="${GITLAB_URL:-http://localhost:8181}"
PAT_FILE="${PAT_FILE:-/tmp/gitlab-pat.txt}"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"

step "1. Fetch upstream template at v${UPSTREAM_VERSION}"

# Only a template really fetched at the tag can be compared on its version pin.
# A local working copy carries the unreleased version, which the fixture must
# not follow.
UPSTREAM_SOURCE="local"

if [ -n "${UPSTREAM_PATH:-}" ] && [ -f "${UPSTREAM_PATH}" ]; then
  cp "${UPSTREAM_PATH}" "${TMP_DIR}/upstream-gitlab-ci.yml"
  ok "using local upstream copy at ${UPSTREAM_PATH}"
else
  # First try curl (online), then fall back to the user's perf-sentinel
  # clone if curl fails (offline-friendly).
  if curl -sSLf -o "${TMP_DIR}/upstream-gitlab-ci.yml" "${UPSTREAM_URL}" 2>/dev/null; then
    UPSTREAM_SOURCE="tag"
    ok "fetched ${UPSTREAM_URL}"
  elif [ -f "${HOME}/RustroverProjects/perf-sentinel/docs/ci-templates/gitlab-ci.yml" ]; then
    cp "${HOME}/RustroverProjects/perf-sentinel/docs/ci-templates/gitlab-ci.yml" \
       "${TMP_DIR}/upstream-gitlab-ci.yml"
    warn "curl failed, fell back to ${HOME}/RustroverProjects/perf-sentinel/docs/ci-templates/gitlab-ci.yml"
  else
    die "cannot fetch upstream template, set UPSTREAM_PATH=/path/to/gitlab-ci.yml"
  fi
fi

UPSTREAM_BYTES=$(wc -c < "${TMP_DIR}/upstream-gitlab-ci.yml")
ok "template size: ${UPSTREAM_BYTES} bytes"

step "2. Lint via GitLab CE CI Lint API"

LINT_VERDICT="SKIPPED"
LINT_NOTE="GitLab CE not reachable"

if curl -sf "${GITLAB_URL}/-/readiness" >/dev/null 2>&1; then
  if [ -f "${PAT_FILE}" ]; then
    TOKEN="$(cat "${PAT_FILE}")"

    # Resolve the test project id. The project-scoped lint endpoint
    # is /api/v4/projects/:id/ci/lint (the global /api/v4/ci/lint was
    # deprecated and 404s on GitLab 17+).
    PROJECT_ID=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
      "${GITLAB_URL}/api/v4/projects?owned=true&search=perf-sentinel-template-test" \
      | python3 -c "
import json, sys
ps = json.load(sys.stdin)
match = [p['id'] for p in ps if p['path'] == 'perf-sentinel-template-test']
print(match[0] if match else '')" 2>/dev/null)

    if [ -z "${PROJECT_ID}" ]; then
      LINT_NOTE="perf-sentinel-template-test project not found, run 'make seed-gitlab-project'"
      warn "skipping lint: ${LINT_NOTE}"
    else
      python3 -c "
import json
content = open('${TMP_DIR}/upstream-gitlab-ci.yml').read()
print(json.dumps({'content': content}))
" > "${TMP_DIR}/lint-payload.json"

      curl -sf -X POST "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/ci/lint" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary "@${TMP_DIR}/lint-payload.json" \
        > "${TMP_DIR}/lint-response.json" \
        || warn "lint API call failed"

      LINT_VALID=$(jq -r '.valid // false' "${TMP_DIR}/lint-response.json" 2>/dev/null || echo false)
      if [ "${LINT_VALID}" = "true" ]; then
        LINT_VERDICT="PASS"
        LINT_NOTE="GitLab CE accepted the upstream YAML (project ${PROJECT_ID} scope)"
        ok "lint PASS, GitLab CE accepted the upstream YAML"
      else
        LINT_VERDICT="FAIL"
        # jq gets the join separator from a here-string, not from an escaped
        # literal: inside single quotes the backslashes reach jq verbatim, the
        # program fails to parse and every lint error read "unknown error".
        LINT_NOTE="$(jq -r '(.errors // []) | join("; ")' "${TMP_DIR}/lint-response.json" 2>/dev/null)"
        [ -n "${LINT_NOTE}" ] || LINT_NOTE="unknown error, raw response in ${TMP_DIR}/lint-response.json"
        warn "lint FAIL: ${LINT_NOTE}"
      fi
    fi
  else
    LINT_NOTE="${PAT_FILE} missing, run 'make seed-gitlab-project' first"
    warn "skipping lint: ${LINT_NOTE}"
  fi
else
  warn "GitLab CE not reachable at ${GITLAB_URL}, skipping lint"
fi

step "3. Parity vs lab fixture"

# Lab fixture is intentionally a derivative (adds integration-tests job,
# pins a specific version). Check structural invariants only.
PARITY_VERDICT="UNKNOWN"

UPSTREAM_HAS_PERF_JOB=$(grep -cE "^perf-sentinel:" "${TMP_DIR}/upstream-gitlab-ci.yml" || true)
FIXTURE_HAS_PERF_JOB=$(grep -cE "^perf-sentinel:" "${LAB_FIXTURE}" || true)
UPSTREAM_HAS_CI_FLAG=$(grep -cE -- "--ci" "${TMP_DIR}/upstream-gitlab-ci.yml" || true)
FIXTURE_HAS_CI_FLAG=$(grep -cE -- "--ci" "${LAB_FIXTURE}" || true)
UPSTREAM_HAS_SARIF=$(grep -cE "sarif" "${TMP_DIR}/upstream-gitlab-ci.yml" || true)
FIXTURE_HAS_SARIF=$(grep -cE "sarif" "${LAB_FIXTURE}" || true)

if [ "${UPSTREAM_HAS_PERF_JOB}" -gt 0 ] && [ "${FIXTURE_HAS_PERF_JOB}" -gt 0 ] \
   && [ "${UPSTREAM_HAS_CI_FLAG}" -gt 0 ] && [ "${FIXTURE_HAS_CI_FLAG}" -gt 0 ] \
   && [ "${UPSTREAM_HAS_SARIF}" -gt 0 ] && [ "${FIXTURE_HAS_SARIF}" -gt 0 ]; then
  PARITY_VERDICT="PASS"
  ok "parity invariants PASS (perf-sentinel job, --ci flag, SARIF artifact)"
else
  PARITY_VERDICT="FAIL"
  warn "parity invariants FAIL (upstream perf-job=${UPSTREAM_HAS_PERF_JOB} fixture=${FIXTURE_HAS_PERF_JOB})"
fi

UPSTREAM_VERSION_PINNED=$(grep -oE 'PERF_SENTINEL_VERSION:\s*"[0-9.]+"' "${TMP_DIR}/upstream-gitlab-ci.yml" || true)
FIXTURE_VERSION_PINNED=$(grep -oE 'PERF_SENTINEL_VERSION:\s*"[0-9.]+"' "${LAB_FIXTURE}" || true)
# The seeded pipeline downloads and runs the release binary the FIXTURE names, so
# a stale pin here means every assertion below it grades a binary nobody ships.
# This read both pins and asserted nothing while they were 9 minor versions apart.
if [ "${UPSTREAM_SOURCE}" != "tag" ]; then
  ok "version pin: fixture=${FIXTURE_VERSION_PINNED:-?}, upstream not compared (template did not come from a tag)"
elif [ -n "${UPSTREAM_VERSION_PINNED}" ] && [ "${UPSTREAM_VERSION_PINNED}" = "${FIXTURE_VERSION_PINNED}" ]; then
  ok "version pin: upstream and fixture agree on ${FIXTURE_VERSION_PINNED}"
else
  PARITY_VERDICT="FAIL"
  warn "version pin drift: upstream=${UPSTREAM_VERSION_PINNED:-?}, fixture=${FIXTURE_VERSION_PINNED:-?}"
fi

step "4. End-to-end: delegate to verify-gitlab-perf-sentinel.sh"

E2E_VERDICT="SKIPPED"
E2E_NOTE="SKIP_E2E=1"

if [ "${SKIP_E2E:-0}" != "1" ]; then
  if [ -x "${GITLAB_VERIFY}" ] || [ -f "${GITLAB_VERIFY}" ]; then
    if curl -sf "${GITLAB_URL}/-/readiness" >/dev/null 2>&1 && [ -f "${PAT_FILE}" ]; then
      ok "running ${GITLAB_VERIFY}"
      if bash "${GITLAB_VERIFY}" > "${TMP_DIR}/e2e.log" 2>&1; then
        E2E_VERDICT="PASS"
        E2E_NOTE="verify-gitlab-perf-sentinel.sh PASS"
        ok "E2E PASS"
      else
        E2E_VERDICT="FAIL"
        E2E_NOTE="verify-gitlab-perf-sentinel.sh FAIL, see ${TMP_DIR}/e2e.log"
        warn "${E2E_NOTE}"
      fi
    else
      E2E_NOTE="GitLab CE not reachable or PAT missing (run 'make up-gitlab && make seed-gitlab-project')"
      warn "${E2E_NOTE}"
    fi
  else
    E2E_NOTE="${GITLAB_VERIFY} not found"
    die "${E2E_NOTE}"
  fi
fi

step "5. Verdict"

# Lint and parity are the hard gates. E2E SKIPPED is acceptable when
# GitLab CE is not deployed. E2E FAIL is a real failure.
if [ "${PARITY_VERDICT}" = "PASS" ] \
   && { [ "${LINT_VERDICT}" = "PASS" ] || [ "${LINT_VERDICT}" = "SKIPPED" ]; } \
   && [ "${E2E_VERDICT}" != "FAIL" ]; then
  if [ "${E2E_VERDICT}" = "PASS" ]; then
    verdict="PASS"
  elif [ "${LINT_VERDICT}" = "PASS" ]; then
    verdict="PARTIAL (E2E SKIPPED, lint+parity PASS)"
  else
    verdict="PARTIAL (lint+E2E SKIPPED, parity PASS)"
  fi
else
  verdict="FAIL"
fi

cat > "${REPORT}" <<EOF
# Scenario report: ${SCENARIO}

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Upstream URL: ${UPSTREAM_URL}
Lab fixture: ${LAB_FIXTURE}

## Step 1: fetch

- ${UPSTREAM_BYTES} bytes fetched

## Step 2: lint via GitLab CE CI Lint API

- verdict: ${LINT_VERDICT}
- note: ${LINT_NOTE}

## Step 3: parity vs lab fixture

- verdict: ${PARITY_VERDICT}
- upstream perf-sentinel job: ${UPSTREAM_HAS_PERF_JOB} hit(s)
- fixture perf-sentinel job: ${FIXTURE_HAS_PERF_JOB} hit(s)
- --ci flag: upstream=${UPSTREAM_HAS_CI_FLAG}, fixture=${FIXTURE_HAS_CI_FLAG}
- SARIF: upstream=${UPSTREAM_HAS_SARIF}, fixture=${FIXTURE_HAS_SARIF}
- version pin: upstream ${UPSTREAM_VERSION_PINNED:-?}, fixture ${FIXTURE_VERSION_PINNED:-?}

## Step 4: end-to-end

- verdict: ${E2E_VERDICT}
- note: ${E2E_NOTE}

## Verdict: ${verdict}

EOF

case "${verdict}" in
  PASS|PARTIAL*)
    color_green "${SCENARIO}: ${verdict}"
    cat "${REPORT}"
    ;;
  *)
    color_red "${SCENARIO}: FAIL"
    cat "${REPORT}"
    exit 1
    ;;
esac
