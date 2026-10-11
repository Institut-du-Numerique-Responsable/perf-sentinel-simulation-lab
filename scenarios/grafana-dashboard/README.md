# Grafana dashboard validation

Validate the upstream `examples/grafana-dashboard.json` end-to-end on
the lab cluster, audit metric coverage against what the daemon exposes,
ship a postgres-exporter overlay, load 5 PrometheusRules, deploy
`postgres-exporter` and unlock the `perf-sentinel report
--pg-stat-prometheus <url>` path.

This scenario absorbs the S2-quater Postgres deep dive : the per-op
coefficient scoring (SELECT 0.5x, INSERT/UPDATE 1.5x, DELETE 1.2x) is
already covered by 3 unit tests upstream
(`crates/sentinel-core/src/score/mod.rs:2053-2188`), so only the
postgres-exporter deployment and the Prometheus path of `--pg-stat`
land here.

## Run

```bash
make verify-grafana-dashboard
# skip the 3 min daemon-down trigger test:
SKIP_TRIGGER_TEST=1 make verify-grafana-dashboard
# skip the 5 min validate-findings traffic step:
SKIP_TRAFFIC=1 make verify-grafana-dashboard
# override the upstream perf-sentinel repo location for the parity check:
UPSTREAM_DASHBOARD_PATH=/path/to/perf-sentinel/examples/grafana-dashboard.json \
  make verify-grafana-dashboard
```

Report lands at `/tmp/scenario-grafana-dashboard-report.md`.

## What it validates

1. **Parity check**. The lab dashboard at
   `manifests/grafana-dashboards/perf-sentinel-overview.json` is
   byte-identical to upstream `examples/grafana-dashboard.json`
   (after `jq --sort-keys` normalization). Drift fails the scenario. The
   same check covers `manifests/grafana-dashboards/perf-sentinel-findings.json`
   against upstream `examples/grafana-findings-dashboard.json`, the
   Infinity dashboard on the query API, whose incidents panels only show
   data once the in-cluster daemon runs 0.20.0 with `[daemon.incidents]`
   and an Infinity datasource carrying `[daemon] read_api_key`.
2. The 17 dashboard panels render against live Prometheus (every `expr`
   returns at least one time series after `make validate-findings`).
3. The 11 perf_sentinel_* metrics referenced by the dashboard are all
   exposed by daemon 0.5.16 (zero broken references).
4. The lab's extended overlay (2 panels, postgres-exporter only)
   imports cleanly and the Grafana sidecar picks it up.
5. The 5 PrometheusRules load via the kube-prometheus-stack operator
   (polled up to 120s for the operator reload to land).
6. `PerfSentinelDaemonDown` fires when the daemon scales to 0
   (end-to-end alert path, polled up to 240s on `/api/v1/rules`). A
   trap restores the daemon to replicas=1 if the script is interrupted
   between scale-down and restore. The other 4 rules are validated
   as "rule loaded and parses" only.
7. postgres-exporter Deployment ready, Service exposed on :9187,
   ServiceMonitor scraped by Prometheus, `pg_stat_statements_seconds_total`
   queryable.

## Coverage audit

Daemon 0.5.16 exposes 11 perf_sentinel_* metrics (the histogram
`perf_sentinel_slow_duration_seconds` shows up as
`_bucket`/`_count`/`_sum` at scrape time, which the audit collapses to
one family). After upstream commit
`feat(examples): expand grafana-dashboard.json from 8 to 17 panels`,
the upstream dashboard covers 11/11 metric families. The lab's
extended overlay only adds 2 postgres-exporter panels.

| Metric | Used by upstream | Used by extended overlay |
| --- | --- | --- |
| `perf_sentinel_findings_total` | yes (4 panels) | no |
| `perf_sentinel_io_waste_ratio` | yes | no |
| `perf_sentinel_active_traces` | yes | no |
| `perf_sentinel_events_processed_total` | yes | no |
| `perf_sentinel_service_io_ops_total` | yes | no |
| `perf_sentinel_slow_duration_seconds` | yes (p95 + heatmap) | no |
| `perf_sentinel_traces_analyzed_total` | yes | no |
| `perf_sentinel_total_io_ops` | yes | no |
| `perf_sentinel_avoidable_io_ops` | yes | no |
| `perf_sentinel_scaphandre_last_scrape_age_seconds` | yes | no |
| `perf_sentinel_cloud_energy_last_scrape_age_seconds` | yes | no |
| `perf_sentinel_export_report_requests_total` | yes | no |
| `up{job="perf-sentinel-daemon"}` | yes (Daemon health) | no |
| `pg_stat_statements_seconds_total` | no | yes (Top 10 slow queries) |
| `pg_stat_statements_calls_total` | no | yes (DB query rate) |

## Upstream backlog (referenced in the original brief, not exposed by 0.5.16)

| Metric | Why it would matter |
| --- | --- |
| `perf_sentinel_co2_grams_total` | GreenOps Phase 9 carbon trend |
| `perf_sentinel_co2_per_request` | GreenOps per-request attribution |
| `perf_sentinel_regional_carbon_intensity` | regional context |
| `perf_sentinel_correlations_total` | cross-trace correlator volume |
| `perf_sentinel_pool_saturation_*` | per-pattern visibility |
| `perf_sentinel_chatty_service_*` | per-pattern visibility |

Tracked in the lab memory's perf-sentinel followup as item 6 (OPEN,
Phase 9 backlog).

## Alert rules

| Alert | Severity | Trigger | Validation |
| --- | --- | --- | --- |
| PerfSentinelDaemonDown | critical | `up == 0 or absent(up) == 1` for 2m | end-to-end (scale to 0, poll for firing) |
| PerfSentinelHighIOWasteRatio | warning | `perf_sentinel_io_waste_ratio > 0.30` for 10m | rule loaded |
| PerfSentinelCriticalFindingsSurge | critical | `increase(...{severity="critical"}[1h]) > 50` for 5m | rule loaded |
| PerfSentinelActiveTracesNearCapacity | warning | `perf_sentinel_active_traces > 8000` for 5m | rule loaded |
| PerfSentinelEventProcessingStalled | warning | `rate(events_processed_total[5m]) == 0` for 5m | rule loaded |

Thresholds (0.30 waste, 50 critical/h, 8000 traces) are starting
points, tune in production. The 50 critical/h threshold sits well
above the lab's `make validate-findings` baseline (~30-50 critical
findings per run) so routine work does not noise the alert. Routing
to Slack/PagerDuty/email stays user-config via Alertmanager `route`
and `receivers`.

## postgres-exporter integration

Deployed in namespace `db` next to Postgres, exposes `:9187`, scraped
every 15s. Credentials sourced from the lab's `postgres-credentials`
Secret via `secretKeyRef`, no hardcoded password. Activates the panels
`Top 10 slow queries (pg_stat)` and `DB query rate (pg_stat)` in the
extended overlay and the Path 2 of `scenarios/pg-stat/verify.sh` :

```bash
# Linux Docker:
docker run --rm \
  --network host \
  -v "${TRACES_FIXTURE}:/input/traces.json:ro" \
  -v /tmp/pg-stat:/output \
  ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.21 \
  report \
    --input /input/traces.json \
    --pg-stat-prometheus "http://localhost:9090" \
    --output /output/dashboard-prometheus.html

# macOS Docker Desktop (the engine runs in a VM, --network host
# does not bridge to the macOS host, use host.docker.internal):
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -v "${TRACES_FIXTURE}:/input/traces.json:ro" \
  -v /tmp/pg-stat:/output \
  ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.21 \
  report \
    --input /input/traces.json \
    --pg-stat-prometheus "http://host.docker.internal:9090" \
    --output /output/dashboard-prometheus.html
```

NetworkPolicies updated in `manifests/network-policies.yaml` (rules
4.J postgres-exporter-egress and 4.J.bis postgres-allow-exporter
appended). DNS egress and Prometheus-scrape ingress were already
covered by the lab's namespace-wide policies, so only
postgres-exporter -> postgres egress and postgres <- postgres-exporter
ingress are new.

## Limitations

- The 4 alert rules other than `PerfSentinelDaemonDown` are validated
  as "rule parses and loads" only. End-to-end firing requires crafted
  load (waste ratio > 0.30, 50+ critical findings/h, 8000+ active
  traces) or stopping the OTLP pipeline.
- postgres-exporter reuses the `lab` user. In production, prefer a
  dedicated read-only role with `pg_read_server_stats` /
  `pg_monitor` grants.
- This scenario is local-only, like the other 8. The
  `validate-on-release.yml` workflow covers minimal sanity targets,
  not the scenario suite (cluster footprint exceeds GHA capacity).
- The parity check needs the upstream perf-sentinel repo at
  `${HOME}/RustroverProjects/perf-sentinel/examples/grafana-dashboard.json`.
  Override via `UPSTREAM_DASHBOARD_PATH=...`. When absent, the parity
  step is SKIPPED (not failed) so the scenario stays runnable. The
  findings dashboard is looked up beside it, override with
  `UPSTREAM_FINDINGS_DASHBOARD_PATH=...`.

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Orchestration, idempotent re-runs, ~10-12 min wall clock with full traffic + trigger |
| `dashboard-extended.json` | 2 lab panels for postgres-exporter (Top 10 slow queries, DB query rate) |
| `postgres-exporter.yaml` | Deployment + Service + ServiceMonitor in namespace `db`, credentials from `postgres-credentials` Secret |
| `alertrules.yaml` | PrometheusRule with 5 alerts in namespace `observability` |

The dashboard JSON itself lives at
`manifests/grafana-dashboards/perf-sentinel-overview.json` (lab)
and `examples/grafana-dashboard.json` (upstream perf-sentinel).
The lab copy is byte-identical to upstream after `jq --sort-keys`.
Bootstrap imports the lab copy into Grafana via the sidecar
pattern, no second import needed. The runtime ConfigMap pattern is
`kubectl create cm --from-file=... | kubectl label grafana_dashboard=1 | kubectl apply`,
the same pattern `scripts/bootstrap.sh` uses. No static
`manifests.yaml` for the dashboards because the JSON files are the
source of truth and the ConfigMap is built from them at apply
time.
