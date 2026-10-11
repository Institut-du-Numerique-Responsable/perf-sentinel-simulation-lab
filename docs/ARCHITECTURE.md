# Architecture

The S1 lab is a local k3d cluster hosting the observability stack
needed to validate perf-sentinel against Java services in S2. No
application service runs in S1, the cluster is only set up to receive
traffic.

## Flow diagram

```
                        Host (macOS)
  ┌──────────────────────────────────────────────────────────┐
  │  localhost:3000  ──┐                  localhost:14318 ──┐│
  │  (Grafana)         │                  (perf-sentinel)   ││
  └────────────────────┼─────────────────────────────────────┘
                       │ kubectl port-forward (background)
                       ▼
  ┌──────────────────────────────────────────────────────────┐
  │ k3d cluster perf-sentinel-lab (1 server + 2 agents)      │
  │                                                          │
  │  ┌──────────────────────────────────────────────────┐    │
  │  │ namespace observability                          │    │
  │  │                                                  │    │
  │  │   OTel Collector (DaemonSet)                     │    │
  │  │     receivers: OTLP gRPC 4317, HTTP 4318         │    │
  │  │     exporters:                                   │    │
  │  │       ├── otlphttp -> tempo:4318                 │    │
  │  │       ├── otlphttp -> victoria-traces:10428      │    │
  │  │       ├── otlphttp -> perf-sentinel-daemon:14318 │    │
  │  │       └── prometheus :8889/metrics               │    │
  │  │                                                  │    │
  │  │   Tempo (single-binary)                          │    │
  │  │     receivers: OTLP 4317/4318, query 3200        │    │
  │  │     storage: local PVC 10Gi                      │    │
  │  │                                                  │    │
  │  │   Victoria Traces (second trace backend)         │    │
  │  │     OTLP insert + Jaeger query on 10428          │    │
  │  │                                                  │    │
  │  │   perf-sentinel daemon                           │    │
  │  │     OTLP HTTP 14318, gRPC 14317                  │    │
  │  │     /metrics, /api/{status,findings,...}         │    │
  │  │                                                  │    │
  │  │   Prometheus + Grafana (kube-prometheus-stack)   │    │
  │  │     Prometheus scrape: ServiceMonitors           │    │
  │  │     Grafana datasources: Prometheus, Tempo       │    │
  │  └──────────────────────────────────────────────────┘    │
  │                                                          │
  │  ┌──────────────────────────────────────────────────┐    │
  │  │ namespace db                                     │    │
  │  │   PostgreSQL 18.3 (StatefulSet, PVC 5Gi)         │    │
  │  │   schemas: orders, payments, notifications       │    │
  │  └──────────────────────────────────────────────────┘    │
  │                                                          │
  │  namespace shop  (empty, reserved for S2)                │
  │  namespace ci    (empty, reserved for S3/S4)             │
  └──────────────────────────────────────────────────────────┘
```

## Manifest direct vs. Helm chart

The lab mixes two installation styles. The split follows three rules:

| Use direct manifest when... | Use Helm chart when... |
| --- | --- |
| The official chart is deprecated (Tempo) | The chart is actively maintained (kube-prometheus-stack, opentelemetry-collector) |
| The upstream chart targets end users with knobs we do not need (perf-sentinel) | The chart's defaults already match what we want |
| The workload is a single StatefulSet/Deployment with a small ConfigMap (Postgres) | The workload spans many resources (CRDs, RBAC, multiple workloads) or we author the chart to match an enterprise pattern (Java services) |

Concretely:

- **Direct manifest**: Tempo (both Grafana charts deprecated), Victoria
  Traces (second trace backend, feeds `batch-victoria-scrape`), perf-sentinel
  daemon (upstream chart wraps choices we override anyway), PostgreSQL
  (single StatefulSet, init via ConfigMap is enough), namespaces,
  Grafana dashboards (loaded as ConfigMap).
- **Helm chart**: kube-prometheus-stack, for its CRDs, operator
  and several workloads. OTel Collector contrib, whose config
  rendering and DaemonSet template are non-trivial. The three
  Java services, one Deployment + Service + Secret +
  ServiceMonitor each. Those three are authored locally, because
  the brief targets parity with enterprise Spring Boot
  deployments, where per-service charts are the convention.

When a chart switches status (e.g. Tempo Operator gets a maintained
chart, or kube-prometheus-stack splits), revisit this split.

## Components and design choices

### Tempo single-binary (direct manifest)

Tempo 3.0.0 is deployed via `manifests/tempo.yaml` in
single-binary mode (`-target=all`). No Helm chart is used. Both
official Grafana charts (`grafana/tempo` and
`grafana/tempo-distributed`) are flagged `deprecated: true`, and
Grafana points to the Tempo Operator, which does not yet have an
officially maintained Helm chart. The direct manifest sidesteps
that friction and reads more clearly.

Single-binary instead of microservices (distributed) because the
distributed variant requires 5 to 9 Tempo pods plus an object store
(S3/MinIO/GCS) even for low throughput. Single-binary fits in
~600 MiB of RAM with the same OTLP ingest protocol.

Trace storage is local on PVC (`/var/tempo/blocks` and
`/var/tempo/wal`). No S3, no GCS. Retention is set to 24 h, the lab
is meant to be used in short investigation sessions rather than
continuously.

A ServiceMonitor ships with the manifest so Prometheus scrapes
`/metrics` on port 3200 (same conventional labels as the other lab
ServiceMonitors).

### kube-prometheus-stack

Pinned chart 84.4.0 (operator v0.90.1). Components disabled to reduce
memory footprint and avoid k3d failures:

- Alertmanager: not relevant in a lab.
- ThanosRuler: same.
- AdmissionWebhooks: these webhooks need cert-manager or manual
  certificates and tend to break the bootstrap.
- defaultRules: the bundled alerting rules (paired with Alertmanager)
  are useless when Alertmanager is off.

ServiceMonitor selectors are open (`{}` everywhere, plus
`serviceMonitorSelectorNilUsesHelmValues: false`). This lets
ServiceMonitors shipped elsewhere (perf-sentinel, OTel Collector,
external charts) be picked up without requiring a specific label. As
a safety net, in-house ServiceMonitors still carry
`release: kube-prometheus-stack` so they remain compatible if we
tighten the selector in S2.

The `observability` namespace is annotated with PodSecurity
`enforce: privileged` because node-exporter requires `hostNetwork`,
`hostPID`, and `hostPath` volumes, which the `baseline` profile
forbids.

### OTel Collector contrib

Chart 0.153.0, contrib image 0.151.0. `daemonset` mode: one instance
per node, simplifies node-level metric collection and prevents the
Collector from becoming a bottleneck when traffic ramps up in S2.

Trace pipeline:

```
OTLP receiver -> memory_limiter -> k8sattributes -> batch
              -> exporters: otlphttp/tempo, otlphttp/perf_sentinel
```

The `k8sattributes` processor enriches each span with Kubernetes
metadata (namespace, deployment, pod, node). Critical so that
perf-sentinel findings can be correlated with the workload that
produced them.

Traces are fan-outed to both exporters. Tempo persists for long-term
navigation in Grafana, perf-sentinel ingests in streaming mode to
produce findings.

### perf-sentinel daemon

Image `ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.16`. The upstream image is
`FROM scratch`, which means:

- No `kubectl exec` (no shell).
- No Docker `HEALTHCHECK`.
- Liveness and readiness probes via `httpGet` on `/health` (always
  exposed, regardless of `[daemon] api_enabled`).

The daemon listens on 14318 (HTTP) and 14317 (gRPC) instead of the
defaults 4318/4317. The override is purely cosmetic from the host's
perspective: it avoids confusion with the standard OTLP ports
exposed by Tempo and the Collector. Inside the cluster each service
has its own IP, so there would not have been a port conflict either
way.

Configuration is injected via a ConfigMap mounted read-only on
`/etc/perf-sentinel/config.toml`:

- `correlation.enabled = true` (default: false). We want to test
  cross-trace detection in S2.
- `n_plus_one_min_occurrences = 5`: low but reasonable threshold to
  catch real N+1 patterns without excessive noise.

A ServiceMonitor scrapes `/metrics` every 30 s. The exposed metrics
(prefix `perf_sentinel_`) feed the `perf-sentinel-overview`
dashboard.

### PostgreSQL 18.3

Single-replica StatefulSet, official image `postgres:18.3-alpine`,
PVC 5 GiB. Three schemas (`orders`, `payments`, `notifications`)
plus three dedicated roles are created on first boot by the
`postgres-init-schemas` ConfigMap.

Explicit decision: a single Postgres instance with three schemas, not
three instances. Lighter on RAM (~300 MiB vs. ~900 MiB), less
realistic than a multi-DB deployment but acceptable for a lab.

The `lab` user password is generated at bootstrap, persisted to
`.postgres-password` (mode 0600, gitignored), and stored in the
`postgres-credentials` Secret. The `make psql` target reads that
file to open a session without prompting.

### Host networking via port-forward

The k3d port mappings (`80:80`, `3000:3000`, `14318:14318`) target
NodePort or LoadBalancer Services. The lab uses ClusterIP Services
and `--disable=servicelb`, so the mappings alone do not reach the
workloads. `bootstrap.sh` finishes by starting `kubectl port-forward`
in the background via `scripts/port-forward.sh`. The PIDs land in
`tmp/pf-*.pid`.

`teardown.sh` (and `make down`) stop the forwards before deleting
the cluster.

## Out of scope

- No TLS between components. Port 443 is exposed by k3d but unused.
  May be added in S3 with GitLab CE.
- No NetworkPolicy between namespaces. Add in S2 if the evaluation
  scenario calls for stricter isolation.
- No auth on the perf-sentinel HTTP API. Local lab, fine.
- No Postgres backup. Data is ephemeral.
- No self-hosted CI/CD. That is S3/S4.

## Java services in the shop namespace

Three Spring Boot 4 services run on Java 25 inside `shop`:

```
order-service        :8080  ──> postgres:5432/lab?schema=orders
                      │
                      ├──> payment-service :8081
                      │     │
                      │     └──> notification-service :8082
                      │
                      └──> calls notification-service for some flows

notification-service :8082  ──> self-loops to /api/external/mock and
                                /api/dispatch/{email,sms,push,...}
```

Each service ships:

- A multistage container image built from
  `services/shared-dockerfile/Dockerfile`. Build stage runs Maven on
  `eclipse-temurin:25-jdk-alpine`. Runtime stage is
  `gcr.io/distroless/java25:nonroot`. The OpenTelemetry Java agent
  v2.27.0 is downloaded in a dedicated stage and copied into
  `/otel/opentelemetry-javaagent.jar`. `JAVA_TOOL_OPTIONS` activates
  the agent at JVM startup.
- A Helm chart in `services/<svc>/helm/`. Values cover image tag,
  service port, database URL, OTel endpoint, ServiceMonitor labels.
  Each chart provisions a Deployment, Service, Secret (filled with
  the postgres password from `.postgres-password` at install time),
  and ServiceMonitor.
- A `/api/fault/*` controller with parameterizable endpoints that
  intentionally produce anti-patterns. The brief mapping lives in
  `scripts/validate-findings.sh`, which is the source of truth on
  which scenario expects which finding type on which service.

### OpenTelemetry instrumentation specifics

The agent runs in `always_on` sampling mode so every trace reaches
the Collector. JDBC and HikariCP instrumentation are enabled
explicitly. The common DB statement sanitizer is disabled
(`OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED=false`),
otherwise the agent rewrites SQL literals to `?` and the
perf-sentinel detector cannot tell N+1 from redundant_sql.

## Validation pipeline

`scripts/validate-findings.sh` orchestrates the twelve k6 scenarios
sequentially. For each entry:

1. The scenario JS is wrapped in a ConfigMap.
2. A Kubernetes Job mounts the ConfigMap and runs `k6 run` against
   the in-cluster service URL.
3. The script waits for the Job to complete, then waits 15 seconds
   for the daemon to flush traces and emit findings.
4. The daemon `/api/findings` endpoint is queried and filtered for
   `(type, service)` matches.
5. PASS if at least one matching finding is present, FAIL otherwise.

The daemon's `trace_ttl_ms` is set to 5 seconds (instead of the
default 60 seconds) so findings emerge quickly enough for the 15s
wait to suffice. Production deployments would use the longer TTL.

The OTel Collector exporter that targets the daemon leaves
`compression` unset, so the OTel default (gzip) applies. The
daemon's `/v1/traces` handler has decompressed request bodies
since 0.5.5, and the lab's old `compression: none` workaround was
removed then (see `docs/TROUBLESHOOTING.md`, "gzip on the daemon
exporter").

The exporter is `otlphttp/perf_sentinel` on `:14318`, so the
nominal lab path is OTLP **HTTP**. The daemon's gRPC listener on
`:14317` is covered by the `otlp-compression-matrix` scenario.
That scenario runs the full transport × encoding matrix against a
throwaway daemon. In its cluster leg it temporarily switches this
collector to `otlp/perf_sentinel` on `:14317`, then reverts. That
separation is deliberate: a single collector exporting to both
ports would ingest every span twice and skew every finding count
in the suite.

## Network segmentation

The lab supports two CNI paths:

- **`make up` (default Flannel path)**: keeps the original flat
  network from k3s's bundled Flannel. NetworkPolicy is silently
  ignored. Useful for debugging non-network issues without the
  policy noise.
- **`make up-cni` (Cilium with NetworkPolicy)**: drops Flannel,
  installs Cilium 1.19.3, and applies zero-trust policies that
  match a typical Onepoint customer's production network shape.
  Calico is documented as a manual fallback. See
  `docs/NETWORK-POLICIES.md` for the policy matrix and debugging
  procedure.

The `cluster/k3d-config.yaml` carries `--flannel-backend=none` and
`--disable-network-policy`, so a fresh cluster waits for a CNI
install before pods become Ready. `make up` still works because the
k3s flags only take effect on the first cluster create; existing
clusters from before this change keep their old Flannel.

## Out of scope (still)

- No service mesh (Istio, Linkerd). NetworkPolicy + Cilium covers
  the segmentation story; HTTP-aware policy is left to a later
  loop.
- No IPv6 dual-stack.
- No multi-cluster (Cilium ClusterMesh) deployment.
