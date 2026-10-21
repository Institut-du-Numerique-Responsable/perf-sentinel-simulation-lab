# alumet-db-waste

Validates perf-sentinel's database-waste feature: the energy of a database
cgroup attributed to the SQL-only avoidable share of the workload and reported
as `green_summary.database_waste`, covering the **measured** path (0.9.13),
the **0.9.14 estimated fallback**, and its **disclosure v1.4** publication.

It builds on the 0.9.12 Alumet backend (see [`alumet-conformance`](../alumet-conformance)).

**0.9.13** added:

- **SQL split**: `green_summary.total_sql_io_ops` / `avoidable_sql_io_ops`,
  the SQL-only slice of the io-op counters (SQL spans, and `n_plus_one_sql` +
  `redundant_sql` findings). The batch side of this is asserted in
  [`sci-functional-unit`](../sci-functional-unit). This scenario covers the
  daemon side end to end.
- **`[green.alumet.database]`**: declares one database cgroup label
  (`label_value`, optional `region`). Each scored window the daemon multiplies
  that cgroup's **measured** window energy by
  `sql_waste_ratio = min(avoidable_sql_io_ops / total_sql_io_ops, 1.0)` and
  reports
  `green_summary.database_waste = { energy_kwh, waste_kwh, waste_gco2, region, sql_waste_ratio, model: "alumet_rapl" }`.
  A **CPU-only lower bound**, **excluded** from the top-level `energy_kwh` and
  from `co2`.

**0.9.14** keeps that measured path byte-for-byte and adds:

- **Estimated fallback on every run**: with no `[green.alumet.database]`
  (every batch `analyze`), the figure is still produced, `model: "estimated"`,
  estimated from the modeled energy of the window's SQL spans. Unlike the
  measured figure it is a **re-presented share of the report totals** (a
  subset of `energy_kwh`/`co2`), never additional energy. A
  declared-but-undelivered database still emits nothing.
- **All three surfaces**: the figure now appears on the text report
  (`analyze`, `Database waste:` line), the `query monitor` Energy tab, and the
  HTML dashboard.
- **Disclosure schema v1.4**: both tiers are now **published** in `disclose`
  as a separate labelled block (per-window `disclosure_waste.database`, period
  `aggregate.database_waste` with a provenance split).
- **Host energy in the totals (0.32.0)**: a measured figure is now **inside**
  `energy_kwh`, `co2.total` and the period totals as a host term, never an
  application's, with its carbon in `carbon_breakdown.database_kgco2eq`.

## Prerequisites

**Self-contained, no cluster.** A local release binary on loopback (ports
14598/14599) + `python3 -m http.server` serving the committed 0.9.12 Alumet
capture augmented with **one synthetic database-cgroup series** carrying a
known joules-per-poll value, so every figure is checkable. Traces are seeded
over the daemon's protobuf OTLP endpoint with the committed `datadog-bridge`
N+1 fixture (and `daemon-analysis-shedding`'s 300-trace payload for leg D).
Docker is not required.

Build the binary under test first:

```bash
cargo build --release -p perf-sentinel   # in the perf-sentinel checkout
make verify-alumet-db-waste              # or: ./scenarios/alumet-db-waste/verify.sh
```

Override `PERF_SENTINEL_LOCAL_BIN` to point at a specific binary. A pre-0.9.13
build produces no measured `database_waste` and a pre-0.9.14 build produces no
estimated fallback / v1.4 disclosure block. That is the built-in negative
control for the corresponding legs.

Legs G/H also read a SQL-heavy N+1 trace fixture
(`../../artifacts/fixtures/em-real-time-traces.json`) with the minimal green
config (`../sci-functional-unit/fixtures/green.toml`), and a pre-v1.4
no-database archive (`../disclose/fixtures/reports-thr5.ndjson`). Leg H runs a
second daemon with green enabled but no `[green.alumet.database]` to bank the
estimated windows.

## Legs

| leg | what it locks |
|-----|---------------|
| **B** | Measured `database_waste` end to end: present with `energy_kwh > 0`; `sql_waste_ratio == avoidable_sql/total_sql`; `waste_kwh == energy_kwh * sql_waste_ratio` (both recomputed); `waste_gco2 > 0`; the DB label never enters the per-service energy maps, and since 0.32.0 the figure is **inside the totals** as a host term: `in_totals` is true, the top-level `energy_kwh` equals the service sum plus the DB `energy_kwh`, and `co2.database_gco2` equals its `energy_gco2`. The archive is **published** in `disclose` as `aggregate.database_waste` (`models = [alumet_rapl]`) with every window in the totals (`in_totals_windows == windows_with_figure`, `in_totals_energy_kwh > 0`) and `carbon_breakdown.database_kgco2eq > 0`, and the period totals do not move vs a database-stripped copy of the same archive (the host kWh then reads as application energy). |
| **C** | Sticky live cell: `database_waste` never flaps to `null` between scrapes, and after the scraper dies it ages out within the TTL (`2 × staleness = 6 × scrape interval`, ≈30 s here) under continued traffic, never pinned to a dead measurement forever. |
| **D** | Carry-over under shedding: with a 1-deep analysis queue and a 20-trace window flooded to shed whole batches, the DB energy summed across the archived NDJSON windows is conserved (quantized to whole scrapes, no vanishing) and the daemon **sheds instead of OOMing**. |
| **E** | Config validation: a `label_value` colliding with `service_mappings`, a typo'd `[green.alumet.databse]`, a `[green.alumet.database]` with no endpoint, and an unknown key inside `[green.alumet]` (the `deny_unknown_fields` compat break) are all **rejected at load**; a charset-valid but unknown `region` only **warns** and yields `database_waste` with `waste_gco2` absent. |
| **F** | `query monitor` Energy tab: the `/api/export/report` snapshot backing `build_energy_lines` carries every field the "Database waste:" line renders; a best-effort headless TUI capture greps the rendered line (the TUI is not driven headless in CI, and its rendering + region sanitization are covered by upstream unit tests). |
| **G** | **Estimated fallback** on batch `analyze` (no `[green.alumet.database]`, no Alumet): `green_summary.database_waste.model == "estimated"`, `energy_kwh > 0` and a subset of the report totals, on all three surfaces: JSON, the text `Database waste:` line tagged `[within the report totals]` (never the measured `[host energy, in the report totals]`), and the HTML dashboard's Database-waste card. |
| **H** | **Disclose v1.4 round-trip** over a mixed archive (measured windows from leg B + estimated windows from a fresh no-DB daemon): `aggregate.database_waste` carries the provenance split (`measured_windows + estimated_windows == windows_with_figure`, `models == {alumet_rapl, estimated}`) while `total_energy_kwh` / `total_carbon_kgco2eq` stay unchanged vs a stripped copy; the official intent accepts the `perf-sentinel-report/v1.4` schema; `verify-hash` `content_hash` round-trips fail-closed; and a pre-v1.4 no-database archive discloses **without** a spurious `database_waste` block (additive-only fields). |
| **I** | Provenance honesty: every estimated archived window tags `model` literally `"estimated"` (never a leaked measured tag), and a **declared-but-undelivered** DB label (declared `[green.alumet.database]` whose cgroup the scraper never serves) emits **no** `database_waste`, with no measured figure and no estimated fallback, so the period never double-counts. |

## Notes

- The database energy is **synthetic** (the lab measures no real cgroup): a
  known `72000 J/poll → 0.1 kWh per 5 s scrape`, riding the same
  memory-as-joules capture the Alumet conformance legs use. Physical realism
  is not the point, checkable arithmetic is.
- The synthetic cgroup label (`pg-cgroup`) is deliberately distinct from any
  `service_mappings` value, since a collision is a config error (leg E).
