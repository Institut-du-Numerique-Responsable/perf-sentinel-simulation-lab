# intent-validator

Regression scenario for the v0.7.0 disclose-time validators: the
`period_coverage` 75% gate and the `intent=official` org-config
required-field validation.

## What it covers

4 sub-tests run inside `ghcr.io/institut-du-numerique-responsable/perf-sentinel:${PERF_SENTINEL_VERSION}`
(defaults to the lab's currently-pinned version):

1. **Internal G1 happy path** (exit 0).
   `disclose --intent internal --confidentiality internal` with the
   complete org-config and the above-coverage archive. Locks the
   simplest successful disclosure path. No gates apply at this
   intent level.

2. **Official G2 happy path** (exit 0).
   `disclose --intent official --confidentiality public` with the
   complete org-config and the above-coverage archive. The 75% gate
   passes (period_coverage = 1.0). Locks the G2 publication path when
   all gates are satisfied.

3. **period_coverage 75% gate** (non-zero exit, grep-stable error).
   Same inputs as sub-test 2 but the below-coverage archive
   (period_coverage = 0.25, far below 0.75). Asserts disclose refuses
   with stderr matching `is below the 75% threshold`. This is the v0.7.0
   contract: official disclosures cannot be published from a period
   with partial Scaphandre / per-service energy coverage.

4. **Org-config required-field validation** (non-zero exit, grep-stable
   error). Above-coverage archive but `org-config-incomplete.toml`
   (missing `organisation.country`). Asserts disclose refuses with
   stderr matching `missing field` and `country`. Locks the contract
   that publishable disclosures require a complete operator-supplied
   org-config.

## Fixtures

```
fixtures/
├── org-config-complete.toml          # all required fields populated
├── org-config-incomplete.toml        # missing organisation.country
├── reports-above-coverage.ndjson     # 4 runtime windows, period_coverage=1.0
└── reports-below-coverage.ndjson     # 1 runtime + 3 fallback, period_coverage=0.25
```

NDJSON archives use the daemon's per-window `Report` shape (struct
`ArchivedReport` upstream, `{"ts": "<rfc3339>", "report": <Report>}`).
A "runtime window" is one with `green_summary.energy_kwh > 0.0` and
non-empty `per_service_energy_kwh`. A "fallback window" has
`energy_kwh = 0.0` and empty per-service maps, simulating an I/O proxy
fallback path.

The complete org-config is a minimal valid configuration covering the
four required-for-official fields: `organisation.name`,
`organisation.country`, `methodology.calibration.carbon_intensity_source`,
`methodology.calibration.specpower_table_version`, and the four core
patterns in `methodology.enabled_patterns`.

## Runtime

CLI-only, ~5 seconds. No cluster contact, no daemon dependency.

Dependencies: `docker`.

## Reproducibility

```
PERF_SENTINEL_VERSION=0.7.2 ./scenarios/intent-validator/verify.sh
```

## Coverage gaps tracked

- **`intent=audited`** is not exercised. The CLI short-circuits
  with exit code 2 in v0.7.x for `audited`. A future sub-test
  should lock that contract once `audited` is genuinely implemented
  upstream.
- **G2 public payload shape** (per-service aggregate) is not asserted
  here, only the exit code. A future sub-test could parse the output
  JSON and check key invariants of the G2 aggregate.

## Which binary this runs against

`scripts/resolve-image.sh` picks the image: `PERF_SENTINEL_IMAGE` (a full
reference, for a locally built pre-release), then `PERF_SENTINEL_VERSION` (a
GHCR tag), then the pin in `manifests/perf-sentinel-daemon.yaml`.

It used to default to a hardcoded old tag, so the scenario ran
green on every release without ever touching the version under
validation. The gate reported a PASS for code it had not executed.
The 0.9.25 round is what surfaced that, and every image-based
scenario now shares this resolution.
