# CI shift-left workflow validation

Primary scenario of the B1 sprint. Validates the canonical perf-sentinel
0.5.17 use case in 3 phases: a clean baseline run with quality gate
passing, a regression run with the gate failing, and an ack workflow run
where the developer marks the findings as acknowledged and the next
pipeline goes green again.

## Run

```bash
make verify-ci-shift-left

# Reuse a previous baseline export (skips ~1 min of clean k6 + ingestion):
SKIP_CLEAN_PHASE=1 make verify-ci-shift-left

# Reuse a previous regression export (skips ~5 min of validate-findings):
SKIP_REGRESSION_PHASE=1 make verify-ci-shift-left

# Override the perf-sentinel CLI image tag:
PERF_SENTINEL_VERSION=0.5.17 make verify-ci-shift-left
```

Report lands at `/tmp/scenario-ci-shift-left-report.md`. Wall clock
~7-10 min on a warm cluster.

## What it validates

### Phase 1: clean baseline

1. New k6 script `scenarios/clean-load.js` exercises only
   `OrderController` endpoints (`GET /api/orders`, `GET /api/orders/{id}`).
   No `/api/fault/*` endpoints.
2. Daemon ingests for 30s, then `/api/export/report` is queried.
3. `perf-sentinel analyze --ci` runs against the clean export with strict
   thresholds (zero-tolerance n+1, io_waste_ratio_max 0.30).
4. **Expected**: the gate passes (exit 0). On a long-lived lab
   cluster with residue findings from prior runs, the gate may
   fail. The verify accepts both outcomes and only fails if
   `analyze` cannot produce an output file.

### Phase 2: regression

1. `make validate-findings` drives 10 k6 fault scripts (n+1 SQL,
   redundant HTTP, chatty service, etc.) against the
   `/api/fault/*` endpoints of `order-service`.
2. Daemon ingests for 30s, fresh `/api/export/report`.
3. `perf-sentinel analyze --ci --format json` then
   `analyze --format sarif`.
4. Assertions:
   - Gate exits non-zero (regression detected).
   - More than 5 active findings.
   - Every finding has a non-empty `signature` field (0.5.17 feature
     `enrich_with_signatures()`, `crates/sentinel-core/src/detect/mod.rs`).
   - SARIF is version 2.1.0 with `tool.driver.name == perf-sentinel`, and
     every result has the 0.35.0 shape: no result-level `logicalLocations`,
     no `fixes`, exactly one location carrying two `logicalLocations`,
     `properties.suggestedFix` a string when present, no `startLine` below 1
     (stdlib python, always run). When `check-jsonschema` is installed and the
     engine checkout carries `tests/fixtures/sarif-schema-2.1.0.json`, the file
     is also validated against the full OASIS schema (override the path with
     `SARIF_SCHEMA`); otherwise the report says the check was structural only.

### Phase 3: ack workflow

1. Unique signatures extracted from the regression analysis.
2. `.perf-sentinel-acknowledgments.toml` generated with one
   `[[acknowledged]]` block per signature, attributed to a placeholder
   address `ci-shift-left@perf-sentinel-lab.invalid`.
3. `analyze --acknowledgments ... --ci` re-runs against the same input.
4. Assertions:
   - Gate passes (acknowledged findings excluded from the gate, 0.5.17
     feature, `crates/sentinel-core/src/acknowledgments.rs`).
   - Zero active findings reported.
   - `--show-acknowledged` re-emits the suppressed findings (probed via
     `acknowledged_findings` field or `findings[].acknowledged` flag).

## Configuration

`.perf-sentinel.toml` ships with strict thresholds suitable for the
regression assertion. Tune for production:

```toml
[thresholds]
n_plus_one_sql_critical_max = 0
n_plus_one_http_warning_max = 0
io_waste_ratio_max = 0.30

[detection]
sanitizer_aware_classification = "strict"

[green]
enabled = true
default_region = "eu-west-3"
```

## Artefacts produced

These files are reused by `output-formats-coverage`:

- `/tmp/ci-shift-left/baseline-report.json`: clean daemon snapshot
- `/tmp/ci-shift-left/regression-report.json`: regression daemon snapshot
- `/tmp/ci-shift-left/regression.json`: analyzed findings (signature
  populated, used by output-formats-coverage 6.A and 6.B)
- `/tmp/ci-shift-left/.perf-sentinel-acknowledgments.toml`: generated
  ack file for the workflow walkthrough

## Limitations

- `--show-acknowledged` output schema is probed across two shapes
  (`acknowledged_findings` vs `findings[].acknowledged`). If
  neither matches, the assertion fails informationally. The
  upstream schema should be confirmed and the verify updated.
- The clean phase tolerates a non-zero gate on long-lived clusters with
  residue findings. To force a strict baseline, run from a freshly
  bootstrapped cluster (`make destroy-up-cni`) before invoking the
  scenario.
- The k6 clean script uses the local port-forward (`localhost:8081`),
  not the in-cluster service DNS. This matches the convention of the 10
  fault scripts in `scenarios/*.js`.

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Orchestration, ~7-10 min wall clock |
| `.perf-sentinel.toml` | Strict thresholds for the quality gate |

The k6 clean script ships at `scenarios/clean-load.js` (lab convention,
alongside the 10 existing fault scripts).
