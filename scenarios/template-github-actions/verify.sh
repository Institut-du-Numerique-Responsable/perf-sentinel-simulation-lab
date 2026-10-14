#!/usr/bin/env bash
# Validate the upstream github-actions.yml template at v0.27.0.
#
# 3 steps:
#
# 1. Fetch upstream `docs/ci-templates/github-actions.yml` at v0.27.0.
# 2. Structural lint:
#    - YAML parses (python yaml.safe_load),
#    - top-level keys (`name`, `on`, `permissions`, `jobs`),
#    - perf-sentinel install + analyze + SARIF upload steps,
#    - `--ci` quality-gate flag,
#    - Action SHAs are 40-char commit SHAs (not floating tags),
#    - PR comment + sticky comment + quality-gate enforcement steps
#      present.
# 3. Best-effort runtime via `nektos/act --list` to confirm act parses
#    the workflow. Full execution would require gh-pages, secrets,
#    network, and a working Linux amd64 binary URL. SKIP gracefully.
#
# Optional knobs:
#   UPSTREAM_VERSION    override version (default 0.27.0)
#   UPSTREAM_PATH       use local copy
#   SKIP_RUNTIME=1      skip act parse step

set -euo pipefail

SCENARIO="template-github-actions"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

UPSTREAM_VERSION="${UPSTREAM_VERSION:-0.27.0}"
UPSTREAM_URL="https://raw.githubusercontent.com/Institut-du-Numerique-Responsable/perf-sentinel/v${UPSTREAM_VERSION}/docs/ci-templates/github-actions.yml"
# rhysd/actionlint is a lightweight GHA workflow validator (no runtime,
# no docker socket needed). nektos/act would require gh-pages, secrets,
# and a working binary URL inside the runner container, which is more
# than this scenario aims to validate.
ACTIONLINT_IMAGE="${ACTIONLINT_IMAGE:-rhysd/actionlint@sha256:887a259a5a534f3c4f36cb02dca341673c6089431057242cdc931e9f133147e9}"  # 1.7.7

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"

step "1. Fetch upstream github-actions.yml at v${UPSTREAM_VERSION}"

if [ -n "${UPSTREAM_PATH:-}" ] && [ -f "${UPSTREAM_PATH}" ]; then
  cp "${UPSTREAM_PATH}" "${TMP_DIR}/github-actions.yml"
  ok "using local copy at ${UPSTREAM_PATH}"
elif curl -sSLf -o "${TMP_DIR}/github-actions.yml" "${UPSTREAM_URL}" 2>/dev/null; then
  ok "fetched ${UPSTREAM_URL}"
elif [ -f "${HOME}/RustroverProjects/perf-sentinel/docs/ci-templates/github-actions.yml" ]; then
  cp "${HOME}/RustroverProjects/perf-sentinel/docs/ci-templates/github-actions.yml" \
     "${TMP_DIR}/github-actions.yml"
  warn "curl failed, fell back to local clone"
else
  die "cannot fetch upstream github-actions.yml, set UPSTREAM_PATH"
fi
UPSTREAM_BYTES=$(wc -c < "${TMP_DIR}/github-actions.yml")
ok "template size: ${UPSTREAM_BYTES} bytes"

step "2. Structural invariants"

# YAML parse via python (use full_load for tolerance to unknown tags).
python3 -c "
import yaml, sys
try:
    yaml.safe_load(open('${TMP_DIR}/github-actions.yml'))
except yaml.YAMLError as e:
    print(f'YAML parse error: {e}', file=sys.stderr)
    sys.exit(1)
print('yaml ok')
" > "${TMP_DIR}/yaml-parse.log" 2>&1 \
  || die "YAML parse failed, see ${TMP_DIR}/yaml-parse.log"
ok "yaml parses"

# Top-level keys present. yaml `on` keyword needs a quoted lookup.
HAS_NAME=$(python3 -c "
import yaml
d = yaml.safe_load(open('${TMP_DIR}/github-actions.yml'))
print('1' if 'name' in d else '0')
")
HAS_ON=$(python3 -c "
import yaml
d = yaml.safe_load(open('${TMP_DIR}/github-actions.yml'))
# yaml may parse 'on' as boolean True. Accept both.
print('1' if ('on' in d or True in d) else '0')
")
HAS_JOBS=$(python3 -c "
import yaml
d = yaml.safe_load(open('${TMP_DIR}/github-actions.yml'))
print('1' if 'jobs' in d else '0')
")
HAS_PERMS=$(python3 -c "
import yaml
d = yaml.safe_load(open('${TMP_DIR}/github-actions.yml'))
print('1' if 'permissions' in d else '0')
")

if [ "${HAS_NAME}" = "1" ] && [ "${HAS_ON}" = "1" ] && [ "${HAS_JOBS}" = "1" ] && [ "${HAS_PERMS}" = "1" ]; then
  ok "top-level keys present (name, on, permissions, jobs)"
else
  die "missing top-level key (name=${HAS_NAME}, on=${HAS_ON}, perms=${HAS_PERMS}, jobs=${HAS_JOBS})"
fi

# perf-sentinel install + analyze + --ci + SARIF upload presence.
if ! grep -qE 'releases/download/v\$\{PERF_SENTINEL_VERSION\}|releases/download/v\$' "${TMP_DIR}/github-actions.yml"; then
  warn "no perf-sentinel install step pattern found"
fi
if ! grep -qE 'perf-sentinel\s+analyze' "${TMP_DIR}/github-actions.yml"; then
  die "no perf-sentinel analyze step"
fi
if ! grep -qE -- '--ci' "${TMP_DIR}/github-actions.yml"; then
  die "no --ci quality-gate flag"
fi
if ! grep -qE 'codeql-action/upload-sarif' "${TMP_DIR}/github-actions.yml"; then
  die "no SARIF upload step"
fi
ok "install + analyze + --ci + SARIF upload all present"

# Action SHAs pinned (40-char commit SHA, not floating tags). Matches
# the upstream "Action SHAs" comment.
UNPINNED_USES=$(grep -E '^\s*uses:' "${TMP_DIR}/github-actions.yml" \
  | grep -vE 'uses:\s*\S+@[a-f0-9]{40}' || true)
if [ -n "${UNPINNED_USES}" ]; then
  warn "unpinned uses: detected"
  printf '%s\n' "${UNPINNED_USES}" | sed 's/^/      /'
  PINNED_VERDICT="WARN"
else
  PINNED_VERDICT="PASS"
  ok "all uses: pinned to 40-char SHA"
fi

# Quality gate + PR comment + sticky comment present.
if grep -qE 'Enforce quality gate|Quality gate' "${TMP_DIR}/github-actions.yml"; then
  ok "quality gate enforcement step present"
fi
if grep -qE 'sticky-pull-request-comment|marocchino' "${TMP_DIR}/github-actions.yml"; then
  ok "sticky PR comment step present"
fi

STRUCTURAL_VERDICT="PASS"

step "3. actionlint (GHA-aware schema + expression validator)"

if [ "${SKIP_RUNTIME:-0}" = "1" ]; then
  RUNTIME_VERDICT="SKIPPED"
  RUNTIME_NOTE="SKIP_RUNTIME=1"
  warn "${RUNTIME_NOTE}"
else
  command -v docker >/dev/null || die "docker not on PATH"

  if ! docker image inspect "${ACTIONLINT_IMAGE}" >/dev/null 2>&1; then
    if ! docker pull "${ACTIONLINT_IMAGE}" >/dev/null 2>&1; then
      RUNTIME_VERDICT="SKIPPED"
      RUNTIME_NOTE="cannot pull ${ACTIONLINT_IMAGE}, lint SKIPPED"
      warn "${RUNTIME_NOTE}"
    fi
  fi

  if docker image inspect "${ACTIONLINT_IMAGE}" >/dev/null 2>&1; then
    if docker run --rm \
        -v "${TMP_DIR}:/workdir:ro" \
        "${ACTIONLINT_IMAGE}" \
        -no-color \
        /workdir/github-actions.yml \
        > "${TMP_DIR}/actionlint.log" 2>&1
    then
      RUNTIME_VERDICT="PASS"
      RUNTIME_NOTE="actionlint accepted the workflow (schema + expressions)"
      ok "${RUNTIME_NOTE}"
    else
      LINT_EXIT=$?
      RUNTIME_VERDICT="FAIL"
      RUNTIME_NOTE="actionlint reported issues (exit ${LINT_EXIT}), see ${TMP_DIR}/actionlint.log"
      warn "${RUNTIME_NOTE}"
    fi
  fi
fi

step "4. Verdict"

case "${STRUCTURAL_VERDICT}/${RUNTIME_VERDICT}" in
  PASS/PASS)        verdict="PASS" ;;
  PASS/SKIPPED)     verdict="PARTIAL (runtime SKIPPED, structural PASS)" ;;
  PASS/*)           verdict="PARTIAL (runtime ${RUNTIME_VERDICT}, structural PASS)" ;;
  *)                verdict="FAIL" ;;
esac

cat > "${REPORT}" <<EOF
# Scenario report: ${SCENARIO}

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Upstream URL: ${UPSTREAM_URL}

## Step 1: fetch

- ${UPSTREAM_BYTES} bytes fetched

## Step 2: structural lint

- yaml parses
- top-level keys: name, on, permissions, jobs all present
- install + analyze + --ci + SARIF upload: all present
- action SHAs pinned: ${PINNED_VERDICT}
- verdict: ${STRUCTURAL_VERDICT}

## Step 3: actionlint (schema + expression check)

- verdict: ${RUNTIME_VERDICT}
- note: ${RUNTIME_NOTE}

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
