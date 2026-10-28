# sarif-warnings-ng

The perf-sentinel SARIF output read by the parser Jenkins Warnings NG runs,
not only by a schema validator.

## Why it exists

0.35.0 made the SARIF output valid against the 2.1.0 schema, and every result
carried one `location`, without `physicalLocation` when the finding had no
usable `code.filepath`. That is valid SARIF, so `ci-shift-left` passed it. The
Warnings NG `sarif` tool goes through analysis-model's `SarifAdapter` to
violations-lib, which throws a `NullPointerException` on such a location and
rejects the whole file. One structural finding (`chatty_service`,
`excessive_fanout`, `pool_saturation`, `serialized_calls`) or one finding
without source attributes was enough to lose every issue in Jenkins. 0.36.0
emits a `location` only with a `physicalLocation` and moves the service and
endpoint to `properties`.

## What it asserts

| id | assertion |
|----|-----------|
| W1 | `analyze --format sarif` on `fixtures/demo.json` yields results both with and without a source file, otherwise the run proves nothing |
| W2 | `SarifAdapter` reads the file without exception, one issue per result |
| W3 | every result with a source file comes back with that file and line |

`fixtures/demo.json` is a copy of the engine's `tests/fixtures/demo.json`:
7 results with a source file, 4 structural ones without. `parser/` holds a
dependency-only `pom.xml` and `ParseSarif.java`, run as a single-file program.

## Run

```bash
make verify-sarif-warnings-ng

# Against a locally built pre-release image:
PERF_SENTINEL_IMAGE=perf-sentinel:0.36.0-<sha> make verify-sarif-warnings-ng

# Another parser version:
ANALYSIS_MODEL_VERSION=14.21.0 make verify-sarif-warnings-ng
```

Docker only, no cluster. Maven downloads go to the `perf-sentinel-lab-m2`
volume. Report at `/tmp/scenario-sarif-warnings-ng-report.md`.

## What it found (2026-10-28)

On 0.35.0, W2 FAIL with `Cannot invoke "PhysicalLocation.getRegion()" because
"physicalLocation" is null` and W3 FAIL, nothing parsed. From 0.36.0, 11 of 11
issues read and the 7 file:line pairs match.
