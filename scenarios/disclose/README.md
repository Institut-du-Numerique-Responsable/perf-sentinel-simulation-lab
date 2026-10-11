# `disclose` scenario

Locks the **v0.8.2 headline feature**: periodic-disclosure two-tier
avoidable waste (schema `perf-sentinel-report/v1.1`). The `disclose`
subcommand aggregates two avoidable-waste tiers from archived per-window
NDJSON:

- `aggregate.canonical_waste`, at the **binary-pinned** N+1 threshold `2`,
  which the operator **cannot** configure (anti-gaming). This is the
  headline, non-manipulable figure. The flat avoidable fields alias it.
- `aggregate.operational_waste`, at the operator's configured N+1 threshold.

## Run

```
make verify-disclose
# or pin a version:
PERF_SENTINEL_VERSION=0.8.2 make verify-disclose   # pin an older binary on purpose
```

Hermetic CLI scenario (no cluster/daemon): `docker run
ghcr.io/institut-du-numerique-responsable/perf-sentinel:${PERF_SENTINEL_VERSION:-0.8.2} disclose` over the
committed fixtures.

## Sub-tests

1. **schema v1.1 + tiers**: `schema_version`,
   `canonical_waste.n_plus_one_threshold == 2`,
   `operational_waste.n_plus_one_threshold == 5`, both tiers
   `energy_kwh`/`carbon_kgco2eq` > 0.
2. **flat-field aliasing**: `estimated_optimization_potential_kgco2eq`,
   `aggregate_waste_ratio`, `aggregate_efficiency_score` alias
   `canonical_waste`.
3. **official intent + verify-hash round-trip**:
   `disclose --intent official` passes the validator (exit 0), and
   `verify-hash` recomputes the `content_hash` to OK on the untampered
   report (FAIL on a tampered copy). This closes the disclose→verify
   round-trip gap that `verify-hash-roundtrip` could not cover. It relies on
   the serde_json `float_roundtrip` fix shipped in v0.8.2.
4. **anti-gaming invariant**: over `reports-thr50` (same workload, operator
   threshold 50), `canonical_waste.n_plus_one_threshold` stays `2`
   (unchanged), while `operational_waste.n_plus_one_threshold` is `50` and
   `canonical_waste.waste_ratio > operational_waste.waste_ratio`. Raising
   the operator threshold under-reports the operational tier, but it cannot
   touch the canonical headline.

## Fixtures

Real v0.8.2-daemon per-window archives harvested during the v0.8.2 release-gate
validation, with the `findings`/`correlations`/`warning_details` arrays trimmed
for size (the tiers live in `disclosure_waste` + `green_summary`, not
`findings`):

- `reports-thr5.ndjson`: operator threshold 5, canonical 2.
- `reports-thr50.ndjson`: same workload, operator threshold 50, canonical 2
  (n+1 reclassified to redundant at the high threshold).
- `org-config.toml`: complete org-config for `intent=official`.
  `specpower_table_version` tracks the pinned image's embedded CCF vintage
  (`2026-04-24` for 0.8.2). Bump it alongside `PERF_SENTINEL_VERSION` if the
  vintage changes.

## Which binary this runs against

`scripts/resolve-image.sh` picks the image: `PERF_SENTINEL_IMAGE` (a full
reference, for a locally built pre-release), then `PERF_SENTINEL_VERSION` (a
GHCR tag), then the pin in `manifests/perf-sentinel-daemon.yaml`.

It used to default to a hardcoded old tag, so the scenario ran green on
every release without ever touching the version under validation. The gate
reported a PASS for code it had not executed. The 0.9.25 round is what
surfaced that, and every image-based scenario now shares this resolution.
