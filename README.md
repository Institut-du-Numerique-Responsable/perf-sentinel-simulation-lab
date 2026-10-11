# Perf Sentinel simulation lab

Local Kubernetes cluster preconfigured to validate perf-sentinel
against instrumented services across many language stacks. The lab
ships an observability stack, eighteen services that intentionally
exhibit performance anti-patterns (three core Java 25 + Spring Boot 4
services plus fifteen multistack services), and a k6 driven validation
pipeline that asserts perf-sentinel classifies each pattern correctly.
It also acts as the pre-tag release gate for perf-sentinel. Each
validated version is recorded in the `release-gate/lab-validations.txt`
ledger of the perf-sentinel repository.

## What it is for

The project is an external consumer of perf-sentinel. It deploys a
local k3d cluster (Cilium CNI, zero-trust NetworkPolicy) with
OpenTelemetry Collector, Tempo, Prometheus, Grafana, perf-sentinel
daemon, PostgreSQL, plus the three core Java services in the `shop`
namespace (`order-service`, `payment-service`, `notification-service`)
that produce the twelve canonical anti-pattern classes on demand via
`/api/fault/*` endpoints. A multistack expansion adds fifteen more
services that reproduce the same anti-patterns across the JVM
(Quarkus, Quarkus + Mutiny, Helidon MP, Helidon SE, Kotlin + Ktor), .NET, Go, NestJS,
Django, FastAPI, PHP (Laravel, Symfony), Ruby on Rails, and Rust
(Diesel, SeaORM). See
[docs/MULTISTACK.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/MULTISTACK.md).

`make seed-services && make validate-findings` runs the twelve k6
scenarios on the core Java services and reports how many anti-patterns
perf-sentinel detected on the expected service. `make verify-all-scenarios`
runs the full suite of deployment, CI, resilience, measured-energy,
and disclosure scenarios, documented in
[docs/SCENARIOS.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/SCENARIOS.md).

## Prerequisites

- macOS (Apple Silicon or Intel) or Linux x86_64.
- Docker Desktop ≥ 4.30 or Colima ≥ 0.7. Allocate at least 8 GiB of
  RAM to Docker.
- `brew install k3d kubectl helm` (minimum versions: k3d 5.x, kubectl
  1.30+, helm 3.14+ or 4.x).
- `python3` (preinstalled on recent macOS) for JSON formatting in
  `make status`. `batch-otlp-file` also needs the `msgpack` module
  (`python3 -m pip install --user msgpack`) to speak the dd-trace v0.4
  wire format; it fails outright without it, where `datadog-bridge`
  skips its live leg instead.
- Network access on first `make up` (Helm charts and the perf-sentinel
  GHCR image).

## Quickstart

```bash
git clone <this-repo> perf-sentinel-simulation-lab
cd perf-sentinel-simulation-lab
make up
open http://localhost:3000   # Grafana, admin / admin
```

`make up` installs Cilium and then bootstraps the stack, about 8 to
10 minutes on the first run. Subsequent runs are faster thanks to the
Docker and Helm caches. After a `k3d cluster start` on an existing
cluster, run `make recover` to bounce Cilium and any not-Ready pods.

## Architecture

High-level view:

```
  App services (shop) ─┐
                       │ OTLP gRPC/HTTP
                       ▼
                  OTel Collector (DaemonSet)
                  ├─ otlphttp ──> Tempo  (trace storage)
                  ├─ otlphttp ──> perf-sentinel daemon  (findings)
                  └─ prometheus :8889/metrics
                                  ▲
   Prometheus  ──── ServiceMonitor scrape ─── perf-sentinel /metrics
       │
       └──> Grafana datasources: Prometheus + Tempo
```

Full details and rationale: [docs/ARCHITECTURE.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/ARCHITECTURE.md).

## What you get

| Service                     | URL                                | Credentials                          |
|-----------------------------|------------------------------------|--------------------------------------|
| Grafana                     | http://localhost:3000              | admin / admin                        |
| perf-sentinel daemon API    | http://localhost:14318             | none (local lab)                     |
| Postgres (cluster-internal) | postgres.db.svc.cluster.local:5432 | user `lab`, see `.postgres-password` |

The host endpoints rely on `kubectl port-forward` started in the
background by `make up`. Stop them with `./scripts/port-forward.sh stop`
or `make down`.

Namespaces:

- `observability`: Tempo, Prometheus, Grafana, OTel Collector,
  perf-sentinel daemon, and the Scaphandre, Kepler, and Redfish energy
  mocks.
- `db`: PostgreSQL 18.3 with the core schemas `orders`, `payments`,
  `notifications`, plus one schema per multistack service.
- `shop`: the application services (the 3 core Java services, and the
  multistack services once seeded).
- `ci`: reserved for in-cluster CI experiments.
- `gitlab-ce`: GitLab CE, deployed on demand by `make up-gitlab` to
  validate the perf-sentinel GitLab CI template.

## Make targets

```bash
make up           # full bootstrap (installs Cilium, then the stack)
make down         # tear down the cluster
make reset        # down then up
make recover      # bounce Cilium + not-Ready pods after a cluster start
make validate     # offline validation (manifests, helm, dashboards, scripts)
make status       # pod status and daemon endpoint health (curl)
make logs         # tail observability namespace logs
make grafana      # open Grafana in the browser
make psql         # open a psql shell against the lab database
make inspect      # launch the perf-sentinel TUI (host binary required)
make help         # list every target

# Service deployment (depends on `make up` first)
make seed-services                         # the 3 core Java services
make seed-quarkus-svc ... seed-symfony-svc # the 15 multistack services (see make help)
make validate-findings                     # 12 k6 scenarios on the core services, assert findings

# Scenario suite
make verify-all-scenarios   # run every scenario (see docs/SCENARIOS.md and make help)
make verify-disclose        # periodic disclosure two-tier waste (schema v1.1)
# plus one verify-<name> target per scenario, listed by make help

# GreenOps and measured energy (optional)
make seed-electricity-maps / verify-electricity-maps
make seed-scaphandre-mock / seed-kepler-mock / seed-redfish-mock / seed-kepler-exporter
make verify-measured-energy-chain

# CNI and network policy
make up-cni / install-cni / reset-cni
make apply-network-policies / remove-network-policies / verify-network-policies
make hubble-ui              # open the Cilium Hubble flow UI

# Utilities
make smoke / ps / redeploy-services / teardown-services / clean-images
make capture-greenops-screenshot

# Limit testing (synthetic I/O-semantic load, see docs/SCENARIOS.md)
make seed-tracegen          # build + import the load-generator image
make seed-daemon-local      # daemon image from a local checkout (pre-release)
make verify-limit-batch-volume / verify-limit-trace-shapes
make verify-limit-service-cardinality / verify-limit-saturation-curve
make verify-limit-multi-source / verify-limit-prod-window-soak

# GitLab CI template validation (optional, ~10 min)
make up-gitlab / seed-gitlab-project / verify-gitlab-perf-sentinel / down-gitlab
```

## Verifications after `make up`

```bash
# 1. All pods Ready
kubectl get pods -A

# 2. Grafana reachable
open http://localhost:3000

# 3. perf-sentinel daemon responding
curl -s http://localhost:14318/api/status | python3 -m json.tool

# 4. No findings yet (none until traffic is injected)
curl -s http://localhost:14318/api/findings | python3 -m json.tool

# 5. Tempo ready
curl -s http://localhost:3200/ready

# 6. Postgres reachable from cluster
make psql
\dn

# 7. Daemon exposes Prometheus metrics
curl -s http://localhost:14318/metrics | grep '^perf_sentinel_'
```

## perf-sentinel configuration

The daemon is configured via the `perf-sentinel-daemon-config`
ConfigMap (mounted on `/etc/perf-sentinel/config.toml`). Lab defaults
relevant to operations:

```toml
[daemon]
listen_address = "0.0.0.0"
listen_port_http = 14318
listen_port_grpc = 14317
max_active_traces = 10000
trace_ttl_ms = 30000              # production-aligned, see manifest comment
api_enabled = true
environment = "staging"

[daemon.correlation]
enabled = true
window_minutes = 5

[detection]
n_plus_one_min_occurrences = 5
sanitizer_aware_classification = "strict"

[green.electricity_maps]           # opt-in, see docs/GREENOPS.md
endpoint = "https://api.electricitymaps.com/v4"
emission_factor_type = "direct"
temporal_granularity = "5_minutes"

[green.electricity_maps.region_map]
"eu-west-3" = "FR"
```

The full ConfigMap with inline comments lives in
[`manifests/perf-sentinel-daemon.yaml`](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/manifests/perf-sentinel-daemon.yaml).
Ports 14317/14318 (instead of the defaults 4317/4318) avoid confusion
with the standard OTLP ports used by Tempo and the OTel Collector.

To change these values, edit `manifests/perf-sentinel-daemon.yaml`,
re-apply with `kubectl apply -f`, then
`kubectl rollout restart deployment/perf-sentinel-daemon -n observability`.

## Core services and anti-patterns

Three Spring Boot 4 services live in the `shop` namespace. Each
exposes one `/api/fault/<pattern>` endpoint per anti-pattern it owns,
plus actuator health and prometheus endpoints.

| Service              | Port | Postgres schema | Faults exposed                                                      |
|----------------------|------|-----------------|---------------------------------------------------------------------|
| order-service        | 8080 | orders          | n_plus_one_sql, redundant_http, slow_sql, pool_saturation, n_plus_one_messaging, slow_messaging |
| payment-service      | 8081 | payments        | redundant_sql, slow_http                                            |
| notification-service | 8082 | notifications   | n_plus_one_http, excessive_fanout, chatty_service, serialized_calls |

Together they cover the twelve canonical detection classes.
`make validate-findings` exercises all twelve through k6 Jobs running
in-cluster and asserts that each scenario produces at least one
matching finding on the expected service. The fifteen multistack
services reproduce the same twelve patterns in other language stacks.
Drive one with `scripts/run-multistack-scenario.sh <stack>`, and see
[docs/MULTISTACK.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/MULTISTACK.md).

## GreenOps integration

The daemon can pull real-time grid carbon intensity from Electricity
Maps to enrich findings (`intensity_source: "real_time"`) and surface
the configured scoring policy in the report dashboard. Optional, the
lab works fine on the bundled `annual` source when no token is
provisioned.

Beyond the proxy and Electricity Maps paths, the daemon ingests
measured energy from Scaphandre (RAPL), Kepler (RAPL, per container),
and Redfish (BMC) exporters. The lab ships Python stdlib mocks for all three, so
those scrape paths run without bare-metal counters. perf-sentinel
0.8.2 added periodic disclosure with two-tier avoidable-waste
reporting (schema v1.1), and 0.8.3 added temporal-coverage
continuity (schema v1.2). The `disclose` and `disclose-temporal`
scenarios lock those contracts.

Setup, sandbox vs trial differences, configuration knobs, and visual
proof: [docs/GREENOPS.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/GREENOPS.md).

## Status

All planned milestones have shipped:

- k3d cluster (Cilium CNI, zero-trust NetworkPolicy), observability
  stack, PostgreSQL, and the perf-sentinel daemon.
- 3 core Java 25 + Spring Boot 4 services with `/api/fault/*`
  endpoints, 12 k6 scenarios, and the validate-findings pipeline.
- A multistack expansion: 15 more services across the JVM (including
  Kotlin + Ktor), .NET, Go, NestJS, Django, FastAPI, PHP, Ruby, and Rust
  ([docs/MULTISTACK.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/MULTISTACK.md)).
- Measured-energy backends (Scaphandre, Kepler, Redfish) and GreenOps
  carbon scoring
  ([docs/GREENOPS.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/GREENOPS.md)).
- GitLab CE for the GitLab CI template
  ([docs/GITLAB-CI.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/GITLAB-CI.md)),
  plus Jenkins and GitHub Actions template scenarios.
- A release gate: the lab is the pre-tag validation for perf-sentinel,
  each PASS recorded in the upstream `release-gate/lab-validations.txt`
  ledger
  ([docs/RELEASE-GATE.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/RELEASE-GATE.md)).

## Troubleshooting

Common errors (port already bound, GHCR pull failure, OOM, blank
dashboard, etc.) and fixes: [docs/TROUBLESHOOTING.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/TROUBLESHOOTING.md).

## Resources

RAM/CPU estimate per component:
[docs/RESOURCES.md](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/docs/RESOURCES.md).

## License

AGPL v3, aligned with perf-sentinel. See [LICENSE](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/blob/main/LICENSE).
