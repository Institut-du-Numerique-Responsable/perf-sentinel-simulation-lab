# Template Jenkinsfile validation

Validates the upstream `docs/ci-templates/jenkinsfile.groovy` template
at the version `verify.sh` pins (`UPSTREAM_VERSION`). Note that the upstream filename is lowercase
`jenkinsfile.groovy`, NOT `Jenkinsfile`. The Multibranch Pipeline plugin
accepts the `.groovy` extension for IDE syntax highlighting.

## Run

```bash
make verify-template-jenkinsfile

# Lint + structural only, skip jenkinsfile-runner:
SKIP_RUNTIME=1 make verify-template-jenkinsfile

# Override version:
UPSTREAM_VERSION=0.35.0 make verify-template-jenkinsfile

# Use a local copy:
UPSTREAM_PATH=~/perf-sentinel/docs/ci-templates/jenkinsfile.groovy \
  make verify-template-jenkinsfile
```

Report at `/tmp/scenario-template-jenkinsfile-report.md`.

## What it validates

1. **Fetch**. Curl upstream at the pinned `UPSTREAM_VERSION`, fallback to the local clone at `PERF_SENTINEL_REPO_PATH` (the pre-release path, before the tag exists).
2. **Structural lint**. Check that the declarative pipeline skeleton is
   present and well-formed:
   - `pipeline { ... }`
   - `stages { ... }` block
   - `perf-sentinel analyze` invocation
   - `--ci` quality-gate flag
   - SARIF output reference
   - `archiveArtifacts` step (warned if missing)
   - `PERF_SENTINEL_VERSION` pin (no floating tags), equal to `UPSTREAM_VERSION`
   - the 0.35.0 shape, read on the code lines only: `Install perf-sentinel`
     is the first stage, the asset is picked by `uname -m` (arm64 included),
     the reports a reused workspace keeps are removed first, and every
     multi-line `sh` block sets `set -eu`, never `pipefail`
3. **Best-effort runtime**. Pull `jenkins/jenkinsfile-runner:latest`
   container and execute the pipeline against a small fixture trace.
   This step is environment-fragile (Java init, plugin downloads,
   binary download from GitHub Releases). Failures are downgraded to
   SKIPPED with a clear note.

## Verdicts

- **PASS**: structural + runtime both PASS.
- **PARTIAL (runtime SKIPPED)**: structural PASS, runtime tolerantly
  skipped due to environment. Acceptable.
- **FAIL**: structural invariants missing (template upstream regression).

## Limitations

- The runtime step uses `jenkinsfile-runner lint` (no actual
  execution, just declarative pipeline parse). Even `lint` has a
  fragility: the bundled image Java cannot reach modern HTTPS
  endpoints (PKIX cert path build failure) when downloading the
  Jenkins WAR on first run. The scenario tolerates this and reports
  SKIPPED with a clear note. Structural lint remains the hard gate.
- The upstream Jenkinsfile downloads the perf-sentinel binary from
  `github.com/Institut-du-Numerique-Responsable/perf-sentinel/releases/v${PERF_SENTINEL_VERSION}/`.
  Real users in CI will hit this URL. The lab does not pre-fetch it.
- `--platform linux/amd64` is forced for ARM hosts (M-series Mac).
- `timeout` is GNU-only. The script falls back to `gtimeout` (brew
  coreutils) or no timeout on stock macOS.

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Fetch + structural + best-effort runtime |
| `.perf-sentinel.toml` | Strict thresholds (matches ci-shift-left) |
