# Troubleshooting

Common errors hit during bootstrap or operation, with their diagnosis
and fix.

## `k3d cluster create` fails with "port already bound"

```
ERRO[0000] Failed Cluster Start: Failed to add one or more helpers
ERRO[0000] Bind for 0.0.0.0:3000 failed: port is already allocated
```

Another process is already listening on 3000, 14318, 80, or 443.
Identify the culprit:

```bash
lsof -nP -iTCP:3000 -sTCP:LISTEN
lsof -nP -iTCP:14318 -sTCP:LISTEN
```

Either free the port or edit `cluster/k3d-config.yaml` to map a
different host port (for example `3001:3000`), then run
`make reset`.

## `docker pull ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.16` fails

Most likely the GHCR image is private or requires a specific account.
Authenticate docker against GHCR:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u <username> --password-stdin
```

If the image does not exist in the public registry at all, fall back
to a local source build:

```bash
cd $PERF_SENTINEL_REPO_PATH
cross build --release --target x86_64-unknown-linux-gnu -p sentinel-cli
mkdir -p build/linux-amd64
cp target/x86_64-unknown-linux-gnu/release/perf-sentinel build/linux-amd64/
docker buildx build --platform linux/amd64 --build-arg TARGETARCH=amd64 \
  -t perf-sentinel:0.5.16 .
```

Then re-run `make up`.

## node-exporter pods stuck `FailedCreate` PodSecurity

If `kubectl get daemonset -n observability` reports `READY 0/3` and
`kubectl describe daemonset` mentions:

```
violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true...)
```

the `observability` namespace is enforcing `baseline`. node-exporter
needs `hostNetwork`, `hostPID`, and `hostPath` volumes, which
baseline forbids. The shipped manifest already sets `privileged` on
this namespace, but if someone overrode the label:

```bash
kubectl label namespace observability \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
kubectl rollout restart daemonset \
  -n observability kube-prometheus-stack-prometheus-node-exporter
```

## `localhost:3000` or `localhost:14318` does not respond

The k3d port mappings (`80:80`, `3000:3000`, `14318:14318`) target
NodePort or LoadBalancer Services. The lab uses ClusterIP Services
plus `--disable=servicelb`, so the port mappings alone do not work.
`bootstrap.sh` starts background `kubectl port-forward` processes via
`scripts/port-forward.sh`.

If the host endpoints do not respond after `make up`:

```bash
./scripts/port-forward.sh stop
./scripts/port-forward.sh start
ls tmp/pf-*.pid
```

To stop cleanly: `./scripts/port-forward.sh stop` (or `make down`,
which does it automatically).

## `k3d image import` fails with `content digest not found`

Intermittent k3d bug on Docker Desktop. Output looks like:

```
ERRO failed to import images in node 'k3d-perf-sentinel-lab-server-0':
ctr: content digest sha256:...: not found
```

`manifests/perf-sentinel-daemon.yaml` references the GHCR image
directly (`ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.4`), so kubelets can
pull at run time. `bootstrap.sh` continues even if the k3d import
fails.

If the import is required for offline operation, recreate the
cluster:

```bash
make down
docker rmi ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.4
docker pull ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.4
make up
```

## `helm upgrade kube-prometheus-stack` times out

```
Error: UPGRADE FAILED: timed out waiting for the condition
```

Often caused by a `prometheus-operator` pod waiting for its admission
webhook. The lab disables webhooks
(`prometheusOperator.admissionWebhooks.enabled: false`). If the
issue persists:

```bash
kubectl -n observability describe pod -l app.kubernetes.io/name=prometheus-operator
kubectl -n observability logs -l app.kubernetes.io/name=prometheus-operator
```

Common cause: a k3d node that ran out of memory. Use `docker stats`
to check.

## perf-sentinel-daemon pod in `CrashLoopBackOff`

```bash
kubectl -n observability describe pod -l app.kubernetes.io/name=perf-sentinel-daemon
kubectl -n observability logs -l app.kubernetes.io/name=perf-sentinel-daemon --previous
```

Causes seen in practice:

- Image not available to the cluster: re-run
  `k3d image import ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.4 -c perf-sentinel-lab`
  or check that the kubelet can reach GHCR.
- Invalid TOML config: check the key names in
  `manifests/perf-sentinel-daemon.yaml` (`[detection]` not `[detect]`,
  `n_plus_one_min_occurrences` not `n_plus_one_sql_threshold`).
- Liveness probe failing: if `/health` does not respond within
  `initialDelaySeconds`, the pod is killed. Bump it to 10 s on slower
  hosts.

## Postgres stuck `Pending`

```bash
kubectl -n db describe statefulset postgres
kubectl -n db describe pvc data-postgres-0
```

Most common cause: no `local-path` StorageClass. Verify:

```bash
kubectl get storageclass
```

If `local-path` is missing, k3s did not start its provisioner.
Destroy the cluster and re-run `make up`.

## Grafana does not load the `perf-sentinel-overview` dashboard

Verify the ConfigMap is properly labeled:

```bash
kubectl -n observability get configmap perf-sentinel-dashboards \
  --show-labels
```

The `grafana_dashboard=1` label must be present, otherwise the
sidecar ignores it. Recreate the ConfigMap manually:

```bash
kubectl -n observability create configmap perf-sentinel-dashboards \
  --from-file=manifests/grafana-dashboards/ \
  --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client | \
  kubectl apply -f -
```

## `perf-sentinel-overview` stays empty after `make up`

Three possible causes, in order:

1. No traffic. In S1 nothing generates traces, so most panels stay at
   zero. Expected. To test, send a manual span with `otel-cli` or
   wait for S2.
2. ServiceMonitor not scraped by Prometheus. In Grafana under
   `Status > Targets`, the `perf-sentinel-daemon` target must be
   `UP`. Otherwise check the `release: kube-prometheus-stack` label
   on the ServiceMonitor and the Prometheus selector.
3. Prometheus datasource misconfigured. In Grafana under
   `Connections > Data sources > Prometheus`, run `Save & test`.

## `make psql` cannot connect

```
psql: error: connection to server at "postgres" failed
```

First test from inside the cluster:

```bash
kubectl -n db run pgcheck --rm -it --restart=Never \
  --image=postgres:18.3-alpine -- \
  psql -h postgres -U lab -d lab
```

If that works but `make psql` does not, check `.postgres-password`
(no trailing newline, mode 0600).

## perf-sentinel reports `suggested_fix: null` and `source_endpoint: unknown`

**Resolved in perf-sentinel 0.5.6.** Framework detection now uses
two complementary signals. The first is the OpenTelemetry
instrumentation scope chain collected from each span's parent
path, which catches `spring-data`, `hibernate`, `quarkus`,
`spring-webflux`, `r2dbc`, `helidon` and `jdbc`. The second is
user-code naming conventions on the JPA rule, namely the
`*Repository`, `*Repo` and `*Dao` suffixes. The lab pins 0.5.6 by
default and JPA findings now carry
`suggested_fix.framework = "java_jpa"` with a populated
`recommendation`. Section kept below for users still on 0.5.5 or
earlier.

### Pre-0.5.6 behavior

perf-sentinel infers the framework (`java_jpa`, `java_quarkus`, `csharp_ef_core`, etc.) from the `code.namespace` attribute on the finding's primary span. For SQL findings the primary span is a JDBC span, which the OpenTelemetry Java agent does not currently enrich with the originating user-code namespace.

In our trace tree:

```
HTTP span             (http.route present)
  └─ Controller span  (code.namespace=com.perfsim.order.web.FaultController)
      └─ Hibernate Query span    (no code.* attributes)
          └─ JDBC span           (no code.* attributes; perf-sentinel reads here)
```

perf-sentinel 0.5.4 does not walk up the parent chain, so it sees
no namespace and emits no `suggested_fix`. perf-sentinel 0.5.5
added the parent walker, but the table `JAVA_RULES` only matched
framework packages. The user-code namespace surfaced by the
walker, `com.example.OrderRepository` for instance, therefore
still failed to match. perf-sentinel 0.5.6 closes both gaps.

`source_endpoint` is similarly read from the immediate parent (Hibernate Query span) rather than from the HTTP server span, hence the `unknown` value.

Historical workarounds explored and dismissed:

- `OTEL_INSTRUMENTATION_COMMON_EXPERIMENTAL_CONTROLLER_TELEMETRY_ENABLED=true` and friends. Add code attributes to controller and repository spans, but not to JDBC spans, so perf-sentinel still sees nothing on the spans it inspects.
- Modifying perf-sentinel to walk parents. Implemented in 0.5.5.
- Extending the framework rules to recognize user-code conventions and using the OpenTelemetry instrumentation scope as a primary signal. Implemented in 0.5.6.

## OTel Collector exporter `compression: none` against the daemon

**Resolved in perf-sentinel 0.5.5.** The daemon's `/v1/traces` handler
now decompresses gzipped request bodies via `tower-http`'s
`RequestDecompressionLayer`, matching the OTLP HTTP spec. The lab's
`helm/values/otel-collector.yaml` no longer sets `compression: none`
on the `otlphttp/perf_sentinel` exporter and lets the OTel default
(gzip) apply.

### Pre-0.5.5 behavior

The daemon used to reject any gzipped OTLP HTTP body with HTTP 400
because `prost::Message::decode` does not understand gzip. Stack
operators on 0.5.4 had to set `compression: none` on every Collector
exporter targeting the daemon, otherwise zero traces reached it.

## Zero spans ingested, healthy daemon, silent counters (gRPC + gzip)

**Resolved in perf-sentinel 0.9.28.** Symptom: the daemon pod is
`Ready`, `/health` answers, and every `/metrics` counter stays at zero
while traffic is flowing. Nothing in the daemon's own logs. The failure
is only visible in the **Collector's** logs:

```
rpc error: code = Unimplemented desc = Content is compressed with `gzip` which isn't supported
```

Up to and including 0.9.26 the OTLP **gRPC** listener never called
`accept_compressed`, and the Collector's OTLP exporter gzips by default.
`Unimplemented` is a permanent error, so the Collector drops each batch
without retrying: a total, silent telemetry loss.

Workaround on 0.9.26 and earlier: set `compression: none` on the
gRPC exporter, or point it at the HTTP endpoint (`:14318`), which
has decompressed gzip since 0.5.5. On 0.9.28+, gzip and deflate
are accepted on both endpoints. `zstd` and `snappy` remain
refused with the same `Unimplemented` and must be changed back to
`gzip` or `none`.

This lab exported over `otlphttp` only, so it never exercised the
broken path. See the `otlp-compression-matrix` scenario, which
now covers the full transport × encoding matrix and A/Bs it
against a pre-fix image.

## OTel JDBC sanitizer disabled to expose N+1 SQL distinct params

**Resolved in perf-sentinel 0.5.7+.** The daemon now recognizes
when the OpenTelemetry SQL statement sanitizer has collapsed N+1
query parameters to `?` placeholders. It reclassifies the
affected groups from `redundant_sql` to `n_plus_one_sql` through
a sanitizer-aware heuristic: the instrumentation scope ORM marker
plus per-span timing variance. Reclassified findings carry a new
`classification_method: "sanitizer_heuristic"` field. The lab no
longer disables the sanitizer in the Java charts and runs in a
production-realistic configuration. The historical workaround
stays documented below for users on 0.5.4 to 0.5.6.

**Note on `strict` mode (introduced in perf-sentinel 0.5.8).** By
default, the daemon runs
`sanitizer_aware_classification = "auto"` which fires the
heuristic on either signal (ORM scope marker OR high timing
variance). That default matches typical production N+1 patterns.
However, applications with cache-warming patterns or polling
repositories that issue many identical SQL queries through an ORM
produce a false positive under `auto`. The ORM scope marker alone
fires the reclassification even when the timing is flat, on a
cached plan with no real N+1 fan-out across rows.

The simulation lab opts in to
`sanitizer_aware_classification = "strict"` in its daemon
ConfigMap (`manifests/perf-sentinel-daemon.yaml`, section
`[detection]`) which requires both signals together. The lab's
`redundant-sql` scenario, 15 cache-warmed
`SELECT count(*) WHERE customer_id = 1` via JPA, consequently
stays classified as `redundant_sql`. The `n-plus-one-sql`
scenario, 15 hits on distinct `order_id`s, still reports, because 15
reaches the high-occurrence bar (three times
`n_plus_one_min_occurrences`), which corroborates on its own whatever
the timing spread. The lab leaves `sanitizer_aware_min_cv` (engine
0.18.0 and later) at its `0.5` default, and the reason is a real
trade-off: raising it to `1.0` stops a loaded PHP-FPM runner from
spreading ten cached repeats past the bar and getting them reported as
`n_plus_one_sql`, but under strict a sanitized group below the
high-occurrence bar has the variance as its only corroborator, so the
threshold moves every such verdict on every stack. `0.5` does not hold
a 12-item Java N+1 steady either: measured on 2026-10-30, 67 of 104
calls of a 12-item native-query loop on `order-service` read
`redundant_sql`, each time the warm JVM kept the variance at or under
`0.5`. `hub-lineage-mutation` therefore sends 15 items, so the bar
decides. The knob is per daemon and this one is shared by every
stack. A real deployment does not serve Java and PHP from one daemon,
so a PHP install can raise it. Production stacks that observe similar
false positives can adopt either opt-in.

### Pre-0.5.7 behavior

The OpenTelemetry Java agent sanitizes `db.statement` by default
and replaces literal values with `?` placeholders to avoid
leaking parameter values (potential PII) into trace storage.
perf-sentinel discriminates `n_plus_one_sql` from `redundant_sql`
by counting `distinct_params` across spans in the same template
group. Distinct values mean a real N+1 that fetched different
rows, identical values mean a redundant call. With the sanitizer
active, every span exposes `params = ["?"]`, so
`distinct_params = 1`, and any N+1 burst gets classified as
`redundant_sql`.

To demonstrate the N+1 SQL classification path, the lab used to set
`OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED=false`
in the three Java service Helm charts. That override never belonged
in production (it leaks SQL literals to traces) but was the only way
to expose the parameter values that the detector needed.

If you operate a stack still on 0.5.4 to 0.5.6 and the
classification looks wrong, with a real N+1 reported as
`redundant_sql`, upgrade to 0.5.7. Otherwise accept that the
sanitizer is masking the discriminator, and read the daemon's
`suggestion` field for an architectural hint.

## NetworkPolicy denials (Cilium path only)

These symptoms apply to clusters bootstrapped via `make up-cni`
(Cilium + NetworkPolicy). The default `make up` (Flannel) path is
unaffected because Flannel ignores NetworkPolicy.

### Symptom: connection hangs

A pod attempts to reach another service and the connection just
hangs (or times out after 30+ seconds). That is the NetworkPolicy
fingerprint: the policy drops the SYN packet without sending RST,
so the client retries until the kernel gives up.

```bash
kubectl exec -n shop deploy/order-service -- timeout 5 nc -z postgres.db 5432
# exit 1 if dropped, exit 0 if reachable
```

If `nc` exits 1 on a pod that should reach Postgres, inspect the
live drop in Hubble:

```bash
cilium hubble observe --verdict DROPPED \
  --pod observability/perf-sentinel-daemon \
  --last 50
```

The output names the policy that did the drop and the labels on the
source and destination, so you can reconcile against
`manifests/network-policies.yaml`.

### Symptom: DNS resolution fails

Pods cannot resolve cluster-internal or external hostnames. Almost
always the `allow-dns-egress` policy is missing for that namespace.
NetworkPolicy is namespaced, so each namespace that runs workloads
needs its own copy.

```bash
kubectl get networkpolicy -A | grep allow-dns
```

### Symptom: GitLab webservice unreachable from the host

The kubectl port-forward routes via the API server, which Cilium
tags as host-network. The lab's `gitlab-webservice-ingress` policy
allows port 8181 from any source for that reason. Tightening this
policy to internal pods only breaks the host port-forward.

### Symptom: Prometheus targets show DOWN

The `allow-prometheus-scrape` policy applies per namespace. Adding
a new namespace with monitored workloads requires extending
`manifests/network-policies.yaml` accordingly.

### Iterating without recreating the cluster

```bash
make remove-network-policies   # drop all policies
# edit manifests/network-policies.yaml
make apply-network-policies
make verify-network-policies
```

### Symptom: pods crashloop on database/DNS errors after a docker restart

When Docker Desktop sleeps or the host hits memory pressure, the
k3d control plane container can restart. On wake, Cilium agents
re-init but their endpoint cache can drift, leaving pod-to-pod
policy enforcement out of sync. Typical signature: shop pods
CrashLoopBackOff with Postgres connection refused, and an
`nslookup postgres.db.svc.cluster.local` from inside the shop
namespace times out. `cilium hubble observe --verdict DROPPED`
then shows shop → kube-system DNS getting denied, even though the
`allow-dns-egress` policy is in place.

Recovery without recreating the cluster:

```bash
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n shop rollout restart deployment/order-service \
  deployment/payment-service deployment/notification-service
```

About 2-3 minutes total. Falls back to `make reset-cni` if the
endpoint drift is too deep (e.g. agents themselves crashloop).

`verify-network-policies.sh` asserts both the deny path (unlabeled
probe blocked) and the allow paths (lab pods reach Postgres, daemon
reaches Electricity Maps, runner reaches GitHub, Prometheus scrapes
the daemon).

## Reset to a clean state

```bash
make down
docker rmi ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.5.4
docker volume prune
rm -f .postgres-password
make up
```
