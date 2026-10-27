# Template GitLab CI validation

Validates the upstream `docs/ci-templates/gitlab-ci.yml` template at
the version `verify.sh` pins (`UPSTREAM_VERSION`) against the in-cluster GitLab CE. Lint + parity + delegation to
the existing `scripts/verify-gitlab-perf-sentinel.sh` end-to-end check.

## Run

```bash
make verify-template-gitlab-ci

# Override version:
UPSTREAM_VERSION=0.35.0 make verify-template-gitlab-ci

# Use a local copy (offline):
UPSTREAM_PATH=~/perf-sentinel/docs/ci-templates/gitlab-ci.yml \
  make verify-template-gitlab-ci

# Lint + parity only, skip the heavy end-to-end:
SKIP_E2E=1 make verify-template-gitlab-ci
```

Report at `/tmp/scenario-template-gitlab-ci-report.md`.

## What it validates

1. **Fetch**. Curl the upstream template at the fixture's pin (`UPSTREAM_VERSION`
   overrides it), falling back to the local clone at `PERF_SENTINEL_REPO_PATH`
   (default `~/RustroverProjects/perf-sentinel/`) when the tag does not exist
   yet, which is the pre-release case.
2. **Lint via GitLab CE CI Lint API**. POST the YAML to
   `/api/v4/ci/lint`, asserts `valid: true`. Catches schema regressions
   that `bash -n` and yq cannot detect (gitlab-specific keywords).
3. **Parity vs lab fixture**. Compares structural invariants between
   the upstream and `artifacts/fixtures/gitlab-ci-from-upstream.yml`:
   - `perf-sentinel:` job declared
   - `--ci` flag present (quality gate enforced)
   - SARIF artifact declared
   - PERF_SENTINEL_VERSION variable pinned (no floating tags)
   - the 0.35.0 shape, in both files: a `perf-sentinel-install` job on
     `stage: .pre` picking the asset by `uname -m` (arm64 included), Code
     Quality entries with `check_name: .type` and `fingerprint: .signature`,
     the line kept at 1 or more, a catch-all rule, and `exit_codes: [75]`
   The lab fixture is intentionally a derivative (adds an
   `integration-tests` dummy job and uncomments the Free-tier Pages
   block), so byte-identity is not the goal.
4. **End-to-end**. Delegates to
   `scripts/verify-gitlab-perf-sentinel.sh` which:
   - clones the seeded `perf-sentinel-template-test` GitLab project,
   - pushes a commit on `main` and asserts the pipeline ends in
     `success` (gate `allow_failure: true` on default branch),
   - opens an MR and asserts the pipeline ends in `failed` (gate
     enforced on MR via `allow_failure: false`),
   - downloads SARIF + perf-sentinel-report.json + Code Quality
     artefacts and asserts they parse and contain the expected schema.
   Skipped when the fixture's pinned release has no published assets yet:
   the seeded pipeline downloads them, so before the tag there is nothing
   to run.

## Verdicts

- **PASS**: lint + parity + E2E all PASS.
- **PARTIAL**: lint or E2E SKIPPED (e.g. GitLab CE not deployed), but
  parity PASS. Acceptable for a CI run that does not bring up GitLab.
- **FAIL**: any hard step fails (lint rejects, parity invariants
  missing, or E2E pipeline produces wrong status).

## Limitations

- The lab fixture has to name a PUBLISHED release, because the seeded
  pipeline downloads that binary from GitHub Releases. It therefore
  cannot follow an unreleased version under validation, and it is
  bumped by hand at release time. Step 3 fails when the fixture pin and
  the fetched template's pin disagree, so the drift cannot stay silent:
  it sat on 0.5.17 against a 0.13.1 template for several releases while
  the scenario reported PASS. During a pre-release pass the fixture
  already names the release under validation: the template comes from
  the local clone, the pins are not compared, and step 4 skips until the
  assets are published.
- `verify-gitlab-perf-sentinel.sh` requires `make up-gitlab && make
  seed-gitlab-project` to have run beforehand. If the fixture project
  doesn't exist yet, the E2E step skips with a clear message.
- The end-to-end run takes ~5-10 min wall clock (GitLab pipeline runs
  the analyzer twice, once on main and once on the MR).

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Lint + parity + E2E delegation |
| `.perf-sentinel.toml` | Strict thresholds (matches ci-shift-left) |
