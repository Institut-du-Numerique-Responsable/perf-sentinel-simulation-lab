# perf-sentinel report --pg-stat live integration

## Use case

Pair the trace-derived anti-pattern findings with database hotspot
data from `pg_stat_statements` in a single HTML dashboard. The
`pg_stat` tab surfaces the top SQL templates by total exec time,
calls, mean exec time, rows returned, and shared block hit/read
counters. The Explain → pg_stat cross-navigation maps each detected
anti-pattern (notably `n_plus_one_sql`, `redundant_sql`, `slow_sql`)
to its matching template row in the pg_stat tab.

## Run

```bash
make verify-pg-stat
```

## What is verified

The verify script:

1. Confirms `pg_stat_statements` is loaded on the lab Postgres.
2. Resets the pg_stat counters.
3. Drives a workload via `make validate-findings` (1500+ SQL queries
   across the 10 anti-pattern scenarios).
4. Dumps `pg_stat_statements` via `psql \copy ... TO STDOUT WITH CSV
   HEADER` to a local CSV.
5. Runs `perf-sentinel report --input <jaeger-traces> --pg-stat <csv>
   --output dashboard.html`.
6. Asserts the HTML dashboard contains pg_stat references (tab,
   templates, cross-nav).

## Configuration

Lab manifest changes that enable pg_stat_statements:

- `manifests/postgres.yaml`: postgres container args
  ```yaml
  args:
    - -c
    - shared_preload_libraries=pg_stat_statements
    - -c
    - pg_stat_statements.track=all
    - -c
    - pg_stat_statements.max=10000
  ```
  `shared_preload_libraries` is a startup-only setting, so toggling it
  requires a Postgres restart.

- `manifests/postgres-init-schemas.yaml`: `CREATE EXTENSION IF NOT
  EXISTS pg_stat_statements;` runs only on first init (when PGDATA is
  empty). On a pre-existing data dir the extension must be created
  manually:
  ```bash
  kubectl -n db exec sts/postgres -- psql -U lab -d lab \
    -c "CREATE EXTENSION pg_stat_statements;"
  ```

## Alternative input: pg_stat via Prometheus

`perf-sentinel report` also accepts `--pg-stat-prometheus <URL>`
pointing at a Prometheus endpoint exposed by `postgres-exporter` with
the `pg_stat_statements` collector enabled. The CLI queries
`topk(N, pg_stat_statements_seconds_total)`
(`crates/sentinel-core/src/ingest/pg_stat.rs:475`) and normalises the
result into the same internal struct the CSV path uses, so both paths
produce identical HTML dashboards.

The lab deploys postgres-exporter via the
[grafana-dashboard scenario](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/scenarios/grafana-dashboard/README.md).
After running `make verify-grafana-dashboard` once, the `verify-pg-stat`
script auto-detects postgres-exporter and exercises Path 2 in addition
to Path 1.

```bash
make verify-grafana-dashboard   # deploys postgres-exporter (one-time)
make verify-pg-stat              # runs both Path 1 (CSV) and Path 2 (Prometheus)
```

When postgres-exporter is absent, Path 2 is skipped (not failed) and
only the CSV path runs, exactly like before. CSV path stays useful for
setups without an exporter.

| Path | Pros | Cons |
| --- | --- | --- |
| 1, CSV via `psql \copy` | Works on any Postgres reachable by `psql`, no exporter required, full pg_stat columns | Manual export step, snapshot only |
| 2, `--pg-stat-prometheus` | Reuses the existing Prometheus scrape, no manual export, time-window aware | Needs postgres-exporter, fewer columns surfaced (the exporter is selective) |

## Output

`/tmp/scenario-pg-stat-report.md` plus the Path 1 dashboard at
`/tmp/pg-stat/dashboard.html`, the CSV at `/tmp/pg-stat/pg-stat.csv`,
and (when Path 2 ran) the Prometheus-sourced dashboard at
`/tmp/pg-stat/dashboard-prometheus.html`.

## Which binary this runs against

`scripts/resolve-image.sh` picks the image: `PERF_SENTINEL_IMAGE` (a full
reference, for a locally built pre-release), then `PERF_SENTINEL_VERSION` (a
GHCR tag), then the pin in `manifests/perf-sentinel-daemon.yaml`.

It used to default to a hardcoded old tag, so the scenario ran
green on every release without ever touching the version under
validation. The gate reported a PASS for code it had not executed.
The 0.9.25 round is what surfaced that, and every image-based
scenario now shares this resolution.
