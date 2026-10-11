# `disclose-temporal` scenario

Locks the **v0.8.3 schema-v1.2 additions** to periodic disclosure, which the
`disclose` scenario (a 0.8.2 / v1.1 contract lock) does not cover:

- `aggregate.temporal_coverage`
  `{temporal_coverage, observed_days, days_in_period, largest_gap_days}`:
  a continuity signal derived from the distinct UTC days carrying archived
  windows. It is traffic-gated, so it is a lower bound on activity, never
  a hard `official` gate.
- `scope_manifest.coverage_basis`: provenance split (operator-asserted vs
  machine-derived scope fields).
- `integrity.cross_period_log`: reserved hook, always absent in v1.2.

## Run

```
make verify-disclose-temporal
# pin / test against a local RC image:
PERF_SENTINEL_VERSION=v0.8.3-rc make verify-disclose-temporal
```

Hermetic CLI scenario (no cluster): `docker run
ghcr.io/institut-du-numerique-responsable/perf-sentinel:${PERF_SENTINEL_VERSION:-0.8.3} disclose` over the
committed fixtures.

## Sub-tests

1. **schema v1.2 + fields**:
   `schema_version == perf-sentinel-report/v1.2`, `temporal_coverage` (4
   subfields), `coverage_basis` (`operator_declared`/`machine_derived`),
   `cross_period_log` absent.
2. **dense continuity**: `temporal_coverage` 1.0, observed == days == 30,
   `largest_gap_days` 0, no stderr warning, in-band `Temporal coverage`
   disclaimer.
3. **sparse continuity**: `temporal_coverage` 0.1 (3/30),
   `largest_gap_days` 14, stderr `temporal coverage is 10.0%` warning,
   in-band disclaimer.
4. **verify-hash round-trip**: content_hash OK on the dense and sparse
   outputs (the 0.8.2 1-ULP guard, now with the `temporal_coverage` float
   in the canonical hash), and FAIL on a tampered copy.
5. **v1.2 validator reject**: official with `total_requests_in_period`
   below `requests_measured` is rejected
   (`requests_measured ... exceeds ... total_requests_in_period`), and no
   file is written.

## Fixtures

Fabricated from a real 0.8.3-daemon archive line by varying only `ts`. The
`findings`/`correlations`/`warning_details` arrays are trimmed, the
aggregator derives `temporal_coverage` from the `ts` dates, and the
tiers/energy live in `disclosure_waste` + `green_summary`:

- `reports-dense.ndjson`: one window per day, 2026-05-08..2026-06-06 (30
  days).
- `reports-sparse.ndjson`: 3 windows on 2026-05-08 / 2026-05-22 /
  2026-06-06 (largest gap 14).
- `org-config.toml`: complete org-config for `intent=official`.
  `specpower_table_version` (`2026-04-24`) tracks the pinned image's
  embedded CCF vintage. Bump it alongside `PERF_SENTINEL_VERSION` if the
  vintage changes.

The period is frozen (`--period-type custom --from 2026-05-08 --to 2026-06-06`)
to match the frozen fixture `ts` values, so the assertions are deterministic.
