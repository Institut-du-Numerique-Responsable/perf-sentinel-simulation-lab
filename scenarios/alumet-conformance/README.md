# alumet-conformance

Validates perf-sentinel 0.9.12's **Alumet** measured-energy backend, the
6th backend and the one leading the measured precedence chain as
`alumet_rapl`, against the **real** upstream `alumet-agent` (v0.9.5
`.deb`) and a frozen capture of its Prometheus exposition. It
pre-validates the product CI job `alumet-wire-conformance` by replaying
its exact steps, then adds the legs only a deterministic wire file
allows.

Self-contained: needs the local release binary
(`cargo build --release -p perf-sentinel`) and python3. **Docker is
optional**: it powers the live legs (A/B/C) which SKIP cleanly without
it. The frozen legs (D/E/F/G) always gate. No cluster.

## Why a real agent AND a frozen capture

Alumet publishes the joules of one source `poll_interval` as a Prometheus
**gauge** (not watts like Scaphandre, not a cumulative counter like
Kepler). perf-sentinel divides by `energy_interval_secs` to recover
watts, and sums every row sharing a `label_key` value. Live procfs values
jitter between our curl and the daemon's scrape, so numeric equality is
only assertable against the committed capture
(`fixtures/alumet-wire-capture.prom`, provenance in
`fixtures/fixture-manifest.json`). The live legs pin the *wire contract*,
the frozen legs pin the *math*.

The daemon coefficient is
`(joules / energy_interval_secs) x scrape_interval_secs / (ops x 3.6e6)`
per op, and the per-batch charge multiplies back by the same op count. So
with one trace POST per scrape window, `per_service_energy_kwh` collapses
to `sum(rows) x scrape_interval / (energy_interval x 3.6e6)`, exact
against a frozen file (verified to machine epsilon during development).

## Assertions

| id | what it locks                                                                                                                                 |
|----|-----------------------------------------------------------------------------------------------------------------------------------------------|
| A  | live exposition captured -> `/tmp/alumet-wire-capture.prom` (product-repo fixture candidate); drift vs the committed fixture is a report note |
| B  | `_alumet` suffix present, `resource_consumer_kind="process"` rows present, the CI job's verbatim discovery pipeline finds a metric name       |
| C  | daemon vs live agent, 4 ticks: `Alumet scraper started`, both warn markers absent, `scrape_total{success}` increments, freshness < 7s         |
| D  | all rows sharing the label value are **summed**: `per_service_energy_kwh == sum(positive process rows) x 5 / 3.6e6` within 1%                 |
| E  | `energy_interval_secs` desync rescales linearly and silently: 5.0 vs 1.0 -> ratio in [4.95, 5.05] plus an absolute check                      |
| F  | Alumet + Scaphandre both configured and matching the same service -> `per_service_energy_model = alumet_rapl` (Alumet outranks)               |
| G1 | mistyped mapping -> no-match warn latches exactly once after 3 ticks while `scrape_total{success}` keeps counting and `failed` stays 0        |
| G2 | empty `service_mappings` -> exactly one startup warn, never recurring                                                                         |
| G3 | `/api/energy` returns 16 rows with `alumet` FIRST: the 7 energy backends, Electricity Maps and the 8 grid operator feeds (0.32.0)         |

## Hard-won wire facts (locked by the 2026-07-16 capture)

- The `.deb` ships `/etc/alumet/alumet-config.toml` **without** a
  `prometheus-exporter` section, but enabling the exporter still works: the
  agent backfills the absent section from the plugin's defaults
  (`prefix = ""`, `suffix = "_alumet"`, `port = 9091`). We point
  `ALUMET_CONFIG` at a fresh path only to capture against a clean, minimal
  config instead of the shipped one.
- The packaged binary carries file capabilities
  (`cap_sys_ptrace,cap_sys_nice,cap_perfmon=ep`). Inside docker the exec
  fails EPERM unless the container adds those caps.
- Upstream's unit-suffix branch is inverted: unit-carrying metrics LOSE the
  unit (`kernel_cpu_time_alumet`, not the user-book's
  `kernel_cpu_time_ms_alumet`) and unitless metrics gain a **trailing
  underscore** (`kernel_context_switches_alumet_`). Metric names are
  therefore always discovered from the wire, never hardcoded.
- `[green.alumet]` alone starts the scraper (visible in `/api/energy`), but
  the measured coefficient only reaches `green_summary` when green scoring is
  enabled (`[green] enabled = true` + a region), matching the
  sci-functional-unit setup.

## Out of lab scope

RAPL on bare metal (powercap) and a dual-socket summed-domain read: no
lab machine exposes RAPL. The summed-label math is covered by leg D on
the real exposition shape (18 process rows sharing one label value). The
RAPL chain itself is documented in the product's `docs/LIMITATIONS.md`.

## Run

```bash
make verify-alumet-conformance
# or
./scenarios/alumet-conformance/verify.sh
```

Report: `/tmp/scenario-alumet-conformance-report.md`.
Knobs: `DAEMON_HTTP_PORT`/`DAEMON_GRPC_PORT` (14498/14499), `AGENT_PORT`
(19091), `MOCK_PORT` (19092), `ALUMET_VERSION` + per-arch
`ALUMET_DEB_SHA256_{ARM64,AMD64}` pins, `DEB_CACHE_DIR`.
