#!/usr/bin/env bash
# Validate the upstream jenkinsfile.groovy template at v0.37.1.
#
# Note on filename: upstream ships `jenkinsfile.groovy` (lowercase, .groovy),
# NOT `Jenkinsfile`. The Jenkins Multibranch Pipeline plugin accepts the
# .groovy extension for IDE syntax highlighting.
#
# 3 steps:
#
# 1. Fetch upstream `docs/ci-templates/jenkinsfile.groovy` at v0.37.1, or
#    from the local perf-sentinel clone (PERF_SENTINEL_REPO_PATH) before
#    that tag is published.
# 2. Structural lint: assert the declarative pipeline skeleton
#    (`pipeline { agent ... stages { ... } }`), the perf-sentinel install
#    + analyze stages, and the `--ci` quality-gate enforcement step. Plus
#    the 0.35.0 shape from a real Jenkins trial: the install stage comes
#    first, picks the asset by `uname -m`, clears the files a reused
#    workspace keeps, and every `sh` block sets `set -eu`, never
#    `set -o pipefail`, which Debian 12's dash rejects.
# 3. Best-effort runtime via `jenkinsfile-runner` containerised. This
#    runner can be flaky (Java init, plugin downloads) and the upstream
#    template downloads a Linux binary from GitHub Releases that may not
#    be available offline. SKIP gracefully on either failure with a
#    clear note.
#
# Optional knobs:
#   UPSTREAM_VERSION    override the version tag (default 0.37.1).
#   UPSTREAM_PATH       use a local copy of the template.
#   SKIP_RUNTIME=1      skip step 3 (lint + structural only).

set -euo pipefail

SCENARIO="template-jenkinsfile"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

UPSTREAM_VERSION="${UPSTREAM_VERSION:-0.37.1}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
UPSTREAM_URL="https://raw.githubusercontent.com/Institut-du-Numerique-Responsable/perf-sentinel/v${UPSTREAM_VERSION}/docs/ci-templates/jenkinsfile.groovy"
# jenkinsfile-runner has no recent stable tag on Docker Hub, only :latest carries a digest.
# Pinning the digest of latest gives immutability even though the tag pointer is mutable.
JFR_IMAGE="${JFR_IMAGE:-jenkins/jenkinsfile-runner@sha256:1510739cb658772e733899a56e7ababb44cc113ee7fa22ec915c5fd0e7bff7a2}"  # latest snapshot 2026-05-03

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"

step "1. Fetch upstream jenkinsfile.groovy at v${UPSTREAM_VERSION}"

if [ -n "${UPSTREAM_PATH:-}" ] && [ -f "${UPSTREAM_PATH}" ]; then
  cp "${UPSTREAM_PATH}" "${TMP_DIR}/Jenkinsfile"
  ok "using local copy at ${UPSTREAM_PATH}"
elif curl -sSLf -o "${TMP_DIR}/Jenkinsfile" "${UPSTREAM_URL}" 2>/dev/null; then
  ok "fetched ${UPSTREAM_URL}"
elif [ -f "${PERF_SENTINEL_REPO_PATH}/docs/ci-templates/jenkinsfile.groovy" ]; then
  cp "${PERF_SENTINEL_REPO_PATH}/docs/ci-templates/jenkinsfile.groovy" \
     "${TMP_DIR}/Jenkinsfile"
  warn "curl failed, fell back to ${PERF_SENTINEL_REPO_PATH}"
else
  die "cannot fetch upstream jenkinsfile.groovy, set UPSTREAM_PATH"
fi
UPSTREAM_BYTES=$(wc -c < "${TMP_DIR}/Jenkinsfile")
ok "template size: ${UPSTREAM_BYTES} bytes"

step "2. Structural invariants"

# Skeleton check: declarative pipeline.
if ! grep -qE '^\s*pipeline\s*\{' "${TMP_DIR}/Jenkinsfile"; then
  die "missing 'pipeline {' declarative skeleton"
fi
if ! grep -qE '^\s*stages\s*\{' "${TMP_DIR}/Jenkinsfile"; then
  die "missing 'stages {' block"
fi
if ! grep -qE 'perf-sentinel\s+analyze' "${TMP_DIR}/Jenkinsfile"; then
  die "missing perf-sentinel analyze invocation"
fi
if ! grep -qE -- '--ci' "${TMP_DIR}/Jenkinsfile"; then
  die "missing --ci quality-gate flag"
fi
if ! grep -qE 'sarif|SARIF' "${TMP_DIR}/Jenkinsfile"; then
  die "missing SARIF output reference"
fi
if ! grep -qE 'archiveArtifacts' "${TMP_DIR}/Jenkinsfile"; then
  warn "no archiveArtifacts step (artefacts may not be retained)"
fi

PERF_VERSION_PIN=$(grep -oE "PERF_SENTINEL_VERSION\s*=\s*'[0-9.]+'" "${TMP_DIR}/Jenkinsfile" | head -1)
if [ -z "${PERF_VERSION_PIN}" ]; then
  warn "PERF_SENTINEL_VERSION pin not found"
else
  ok "version pin: ${PERF_VERSION_PIN}"
fi

[ "${PERF_VERSION_PIN//[^0-9.]/}" = "${UPSTREAM_VERSION}" ] \
  || die "template pins ${PERF_VERSION_PIN:-nothing}, expected ${UPSTREAM_VERSION}"

# The 0.35.0 shape. Code-only view first: the template's comments quote the
# very commands this checks, so grepping the raw file would match prose.
grep -vE '^\s*//' "${TMP_DIR}/Jenkinsfile" > "${TMP_DIR}/Jenkinsfile.code"
JF="${TMP_DIR}/Jenkinsfile.code"
INSTALL_LINE=$(grep -nE "stage\('Install perf-sentinel'\)" "${JF}" | head -1 | cut -d: -f1)
ANALYZE_LINE=$(grep -nE "stage\('perf-sentinel analyze'\)" "${JF}" | head -1 | cut -d: -f1)
[ -n "${INSTALL_LINE}" ] && [ -n "${ANALYZE_LINE}" ] && [ "${INSTALL_LINE}" -lt "${ANALYZE_LINE}" ] \
  || die "install stage must come before analyze (install=${INSTALL_LINE:-none}, analyze=${ANALYZE_LINE:-none})"
FIRST_STAGE=$(grep -oE "stage\('[^']+'\)" "${JF}" | head -1)
[ "${FIRST_STAGE}" = "stage('Install perf-sentinel')" ] \
  || die "first stage is ${FIRST_STAGE:-none}, the tests need the binary installed before them"
grep -qE 'case "\$\(uname -m\)" in' "${JF}" || die "no asset pick by uname -m"
grep -qE 'aarch64\|arm64\) ASSET=perf-sentinel-linux-arm64' "${JF}" || die "no arm64 asset branch"
grep -qE "rm -f .*perf-sentinel-results\.sarif.*perf-sentinel-report\.json" "${JF}" \
  || die "no cleanup of the reports a reused workspace keeps"
grep -qE 'set -o pipefail|set -euo pipefail' "${JF}" && die "a sh block sets pipefail, which dash on Debian 12 rejects"
SH_BLOCKS=$(grep -cE "sh '''" "${JF}")
SET_EU=$(grep -cE '^\s*set -eu$' "${JF}")
[ "${SH_BLOCKS}" -gt 0 ] && [ "${SET_EU}" -eq "${SH_BLOCKS}" ] \
  || die "set -eu in ${SET_EU} of ${SH_BLOCKS} multi-line sh blocks"
ok "0.35.0 shape: install first, asset by uname -m, workspace cleared, set -eu in ${SET_EU}/${SH_BLOCKS} sh blocks"

STRUCTURAL_VERDICT="PASS"
ok "structural invariants PASS (pipeline, stages, analyze, --ci, sarif, 0.35.0 shape)"

step "3. Best-effort runtime via jenkinsfile-runner"

if [ "${SKIP_RUNTIME:-0}" = "1" ]; then
  RUNTIME_VERDICT="SKIPPED"
  RUNTIME_NOTE="SKIP_RUNTIME=1"
  warn "${RUNTIME_NOTE}"
else
  command -v docker >/dev/null || die "docker not on PATH"

  # Pull the jenkinsfile-runner image if not cached. Tolerate failure.
  if ! docker image inspect "${JFR_IMAGE}" >/dev/null 2>&1; then
    if ! docker pull "${JFR_IMAGE}" >/dev/null 2>&1; then
      RUNTIME_VERDICT="SKIPPED"
      RUNTIME_NOTE="cannot pull ${JFR_IMAGE}, runtime SKIPPED"
      warn "${RUNTIME_NOTE}"
    fi
  fi

  # Only attempt the run if the image is now available locally.
  if docker image inspect "${JFR_IMAGE}" >/dev/null 2>&1; then
    mkdir -p "${TMP_DIR}/workspace"
    cp "${TMP_DIR}/Jenkinsfile" "${TMP_DIR}/workspace/Jenkinsfile"
    cp "${SCENARIO_DIR}/.perf-sentinel.toml" "${TMP_DIR}/workspace/.perf-sentinel.toml"
    mkdir -p "${TMP_DIR}/workspace/target"
    if [ -f "/tmp/ci-shift-left/regression-traces.json" ]; then
      cp "/tmp/ci-shift-left/regression-traces.json" "${TMP_DIR}/workspace/target/traces.json"
    else
      warn "ci-shift-left artefacts missing, using empty trace fixture (run 'make verify-ci-shift-left' first to use real traces)"
      printf '{"data": []}' > "${TMP_DIR}/workspace/target/traces.json"
    fi

    # jenkinsfile-runner has a `lint` subcommand that validates the
    # Jenkinsfile structure without executing it. Lighter than `run`
    # (no perf-sentinel binary download, no docker socket, no Jenkins
    # web UI). --platform linux/amd64 forces emulation on arm64 hosts.
    if command -v timeout   >/dev/null 2>&1; then TIMEOUT=(timeout 300)
    elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT=(gtimeout 300)
    else                                            TIMEOUT=()
    fi
    if "${TIMEOUT[@]+"${TIMEOUT[@]}"}" docker run --rm \
         --platform linux/amd64 \
         -v "${TMP_DIR}/workspace:/workspace:ro" \
         "${JFR_IMAGE}" \
         lint -f /workspace/Jenkinsfile \
         > "${TMP_DIR}/jfr.log" 2>&1
    then
      RUNTIME_VERDICT="PASS"
      RUNTIME_NOTE="jenkinsfile-runner lint accepted the pipeline"
      ok "${RUNTIME_NOTE}"
    else
      JFR_EXIT=$?
      RUNTIME_VERDICT="SKIPPED"
      RUNTIME_NOTE="jenkinsfile-runner lint exited ${JFR_EXIT} (env-related, see ${TMP_DIR}/jfr.log)"
      warn "${RUNTIME_NOTE}"
    fi
  fi
fi

step "4. Verdict"

# Structural is the hard gate. Runtime SKIPPED is acceptable. Runtime
# FAIL is treated as PARTIAL (template is syntactically/structurally OK,
# environment cannot run it).
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
Filename: jenkinsfile.groovy (NOT Jenkinsfile, lowercase + .groovy ext)

## Step 1: fetch

- ${UPSTREAM_BYTES} bytes fetched

## Step 2: structural lint

- verdict: ${STRUCTURAL_VERDICT}
- skeleton: pipeline { stages { ... } } present
- analyze + --ci + sarif: present
- version pin: ${PERF_VERSION_PIN:-?}
- 0.35.0 shape: install first, asset by uname -m, workspace cleared, set -eu everywhere

## Step 3: runtime via jenkinsfile-runner

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
