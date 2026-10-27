# Template GitHub Actions validation

Validates the upstream `docs/ci-templates/github-actions.yml` workflow
at the version `verify.sh` pins (`UPSTREAM_VERSION`). Structural lint + best-effort `act --list` parse check.

## Run

```bash
make verify-template-github-actions

# Lint + structural only:
SKIP_RUNTIME=1 make verify-template-github-actions

# Override version:
UPSTREAM_VERSION=0.35.0 make verify-template-github-actions

# Use a local copy:
UPSTREAM_PATH=~/perf-sentinel/docs/ci-templates/github-actions.yml \
  make verify-template-github-actions
```

Report at `/tmp/scenario-template-github-actions-report.md`.

## What it validates

1. **Fetch**. Curl upstream at the pinned `UPSTREAM_VERSION`, fallback to the local clone at `PERF_SENTINEL_REPO_PATH` (the pre-release path, before the tag exists).
2. **Structural lint**:
   - YAML parses (python `yaml.safe_load`).
   - Top-level keys present: `name`, `on`, `permissions`, `jobs`.
   - perf-sentinel binary install step (release URL pattern).
   - `perf-sentinel analyze` step.
   - `--ci` quality-gate flag.
   - `github/codeql-action/upload-sarif` step.
   - the template's `PERF_SENTINEL_VERSION` equals `UPSTREAM_VERSION`.
   - `uses:` declarations pinned to 40-character commit SHAs (no
     floating tags). Warning if any are unpinned.
   - Quality gate enforcement step.
   - PR comment + sticky comment plugin presence.
3. **actionlint**. Run `rhysd/actionlint` against the workflow.
   This is a GHA-aware schema + expression validator (catches
   bad expressions, invalid `if:` conditions, unknown context
   refs, dead needs:, etc.). Lighter than running act in a
   container and does not require gh-pages/secrets. Failures
   downgrade to FAIL only when the lint reports issues. Pull
   failures downgrade to SKIPPED.

## Verdicts

- **PASS**: structural + actionlint both PASS.
- **PARTIAL**: structural PASS, actionlint SKIPPED (image pull failed).
  Acceptable.
- **FAIL**: YAML parse fails, a required step is missing, or
  actionlint reports issues.

## Limitations

- `actionlint` validates static structure (schema, expressions,
  shell-script syntax inside `run:`) but does not execute the
  workflow. Real GHA-only behaviors (secrets resolution, gh-pages
  pushes, third-party Actions outcomes) are not exercised.
- The template's binary install step downloads from
  `github.com/Institut-du-Numerique-Responsable/perf-sentinel/releases/...`. Real workflow runs
  in GHA depend on this URL being reachable and the release artefact
  being present. The lab does not validate the binary's actual
  download here.
- `rhysd/actionlint` image pull failures (network) are tolerated.

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Fetch + structural + act --list |
| `.perf-sentinel.toml` | Strict thresholds (matches ci-shift-left) |
