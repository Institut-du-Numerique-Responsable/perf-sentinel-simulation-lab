# chart-disclose-persistence

Proves that the upstream Helm chart's `StatefulSet` + persistence mode
actually delivers a working, restart-surviving disclosure archive when
installed for real, not just that it renders correctly.

## Why this scenario exists

Three other pieces of coverage sit next to each other but never chain
together:

- **`disclose` / `disclose-temporal`** lock the report schema and
  aggregation logic, hermetically, against committed NDJSON fixtures. They
  never touch the chart or a cluster.
- **`chart-prometheusrule-pdb`** is the only other scenario that renders
  and installs the real chart, `charts/perf-sentinel/` in the
  perf-sentinel repo. The lab does not vendor it, and the shared
  observability daemon ships via `manifests/perf-sentinel-daemon.yaml`.
  That scenario locks Phase A only, `PrometheusRule` +
  `PodDisruptionBudget`, not persistence.
- **`daemon-ack-workflow`** proves PVC-backed persistence survives a
  rollout restart, but against the lab's own hand-written manifest. It
  never goes through the chart's `StatefulSet` template, nor through the
  auto-injection in `templates/configmap.yaml` that points
  `[daemon.ack] storage_path` and `[daemon.archive] path` at the mounted
  PVC.

So the chart's render-time guards are unit-tested by
`scripts/test/chart-render-guards-test.sh` in the perf-sentinel repo, and
`StatefulSet`+persistence is schema-validated by `helm-ci.yml`'s
`template-matrix` leg. But nobody installs it and proves the archive comes
back after a pod is rescheduled. Chart `0.2.57` shipped exactly that class
of bug once already. The PVC was mounted at `/var/lib/perf-sentinel` but
nothing pointed at it, so the ack store fell back to a non-writable
default and disclose archiving stayed silently inert despite
`persistence.enabled=true`. This scenario is the live regression net.

## Two constraints worth knowing before reading `verify.sh`

**The daemon image is `FROM scratch`**: no shell, no `tar`, nothing but the
binary. `kubectl exec` and `kubectl cp` against the perf-sentinel pod are
both non-starters. File inspection goes through a throwaway `busybox` pod
mounting the *same* PVC, and since that PVC is `ReadWriteOnce`, the pod can
only attach while the `StatefulSet` is scaled to 0. That is why the sequence
below scales down before every read. The read appends an `__ARCHIVE_OK__`
sentinel inside the exec'd command so a swallowed `kubectl` failure is never
mistaken for a legitimately empty archive, the same guard
`daemon-sigterm-drain` uses.

**Scaling to 0 is load-bearing, not just PVC hygiene.** The archive writer
buffers into a `BufWriter` and only flushes on rotation (`max_size_mb`,
100 MB) or the graceful `SIGTERM` drain. A trace leaving the correlation
window (`active_traces` back to 0) therefore does *not* mean its window is
on disk yet. The scale-down is what persists it.

## Which chart gets installed

`CHART_SOURCE` decides, and the resolved version is always passed to helm as an
explicit `--version` (the lab requires that on every `helm install`, see
docs/SCENARIOS.md "Supply chain pinning"):

| `CHART_SOURCE`   | Resolution                                                                           | Role                                                           |
|------------------|--------------------------------------------------------------------------------------|----------------------------------------------------------------|
| `auto` (default) | local working-tree chart when its version is **newer** than the newest published one | pre-publication release candidate, the gate the lab exists for |
| `auto`           | otherwise the newest published OCI chart                                             | no pending release, so test what users actually pull           |
| `auto`           | **dies** when the newest published version cannot be resolved                        | see below                                                      |
| `oci`            | force the newest published chart                                                     |                                                                |
| `local`          | force `PERF_SENTINEL_CHART`                                                          |                                                                |

`CHART_VERSION=X.Y.Z` pins explicitly and genuinely skips registry
resolution, so it is the escape hatch when the tag list is unreachable. In
`local` mode it is only accepted when it matches `Chart.yaml`. Helm
resolves a directory chart by path and ignores `--version` outright, so
honouring a different value would make the report name a version that was
never installed.

`auto` deliberately does **not** fall back to the local chart when the
registry is unreachable. That fallback would let a stale checkout be
installed, PASSed and written into the release-gate ledger as if it were
the published chart. The cosign leg would be silently skipped on top. An
unreachable registry makes a run inconclusive, not green, so it stops and
tells you to choose explicitly.

The newest published version comes from the anonymous GHCR Registry v2 tag
list, the same shape as the product's `scripts/release-chart.sh`
`check_ghcr_image()`. The `?n=1000` page size is load-bearing: this repository
carries 86 tags and the default page truncates inside the retired `0.2.x` line,
so an unpaginated read would resolve "newest" to `0.2.43`. A `Link: rel=next`
on the response means the page was still capped and the scenario refuses rather
than installing an ancient chart.

In `oci` mode the scenario needs **no perf-sentinel checkout at all**, which is
what makes it runnable where the product source is absent, unlike
`chart-prometheusrule-pdb`.

The daemon image defaults to what the chart itself selects:
`image.repository`, with `image.tag` falling back to `appVersion`. The run
therefore exercises the chart/daemon pairing a real user gets, rather than
a combination nobody deploys.

`DAEMON_IMAGE=repo:tag` overrides it. That is required for a genuine
release-candidate run. A locally bumped chart names an `appVersion` whose
image is only pushed at tag time, so without an override the pod sits in
ImagePullBackOff and the install times out. Build and import one first
with `scripts/seed-daemon-local.sh`.

## Sequence

```
resolve    CHART_SOURCE -> chart ref + explicit --version; helm show chart/values
           -> appVersion and image.repository
install    helm install (workload.kind=StatefulSet, persistence.enabled=true) --wait
provenance record the source/version/appVersion actually certified and assert the pod
           runs the image the chart's appVersion selects
cosign     verify the keyless signature (OCI mode only, SKIP when cosign is absent)
wiring     read the live ConfigMap key `perf-sentinel.toml`: [daemon.ack] storage_path
           and [daemon.archive] path both present under /var/lib/perf-sentinel
inject     port-forward, POST the shared N+1 fixture (daemon-sigterm-drain/fixtures),
           poll /api/status until active_traces reaches 0 (bounded wait, not the flush)
pre-read   scale to 0 (drains + frees the RWO PVC) -> busybox reader -> expect >= 1 window
restart    scale to 1 -> ordinal 0 reattaches the same PVC by identity -> /health OK
post-read  scale to 0 again -> busybox reader -> archive.ndjson
compare    the pre-restart bytes must still be the head of the post-restart file (prefix,
           not equality: the archive is append-only and the daemon may legitimately flush
           another window meanwhile). Guarded by pre >= 1 window, so two empty files
           cannot pass.
disclose   docker run -u $(id -u):$(id -g) <image> disclose --intent internal
           --input post-restart.ndjson --org-config fixtures/org-config.toml
           -> exit 0 AND the aggregate reports >= 1 window and >= 1 anti-pattern
cleanup    helm uninstall + delete the scenario namespace (also drops the PVC)
```

## Verdict

PASS when every sub-check holds: `helm-install`, `chart-provenance`,
`configmap-wiring`, `archive-write` (>= 1 window before restart),
`persistence` (byte-identical after restart), `disclose-roundtrip`, plus
`cosign-verify` when it can run. Checks that cannot run because an earlier step
did not produce their input record SKIP rather than a misleading FAIL. The
per-check table lands in `/tmp/scenario-chart-disclose-persistence-report.md`
and names the chart source and version the run certifies.

`disclose-roundtrip` deliberately asserts the aggregate's window count and
anti-pattern count rather than the presence of `schema_version` /
`aggregate`. Those two are non-optional fields of `PeriodicReport`, so
checking for them would pass for any report the binary can emit, and prove
nothing about the persisted archive having been read.

## Inputs

| Variable               | Default                                           | Notes                                                                       |
|------------------------|---------------------------------------------------|-----------------------------------------------------------------------------|
| `CHART_SOURCE`         | `auto`                                            | `auto` / `oci` / `local`, see the resolution table above                    |
| `CHART_VERSION`        | resolved                                          | pin a chart version and skip registry resolution                            |
| `DAEMON_IMAGE`         | what the chart selects                            | `repo:tag` override, required for a release-candidate run                   |
| `PERF_SENTINEL_CHART`  | `${PERF_SENTINEL_REPO_PATH}/charts/perf-sentinel` | local chart path, used in `local` mode                                      |
| `OCI_CHART`            | `oci://ghcr.io/institut-du-numerique-responsable/charts/perf-sentinel`     | published chart reference                                                   |
| `LOCAL_PORT`           | `14418`                                           | host port for this scenario's port-forward (the shared daemon uses `14318`) |
| `ARCHIVE_WAIT_TIMEOUT` | `90`                                              | wall-clock seconds to wait for the trace to leave the window                |
| `PVC_UTIL_IMAGE`       | `busybox:1.37`                                    | archive reader pod image                                                    |
| `KEEP_NAMESPACE`       | `no`                                              | `yes` skips cleanup (debugging)                                             |

## Runtime prerequisites

- A cluster. The full lab (`make up-cni`) works, but so does a bare
  `k3d cluster create <name> --servers 1 --agents 0`. The scenario creates
  its own namespace and references neither `observability`, nor Cilium,
  nor any seeded service. It does not need `make seed-services`, and it
  does not need the 8-10 minute Cilium bootstrap. `--agents 0` also
  sidesteps node affinity on the ReadWriteOnce PVC.
- The shared N+1 OTLP fixture at
  `scenarios/daemon-sigterm-drain/fixtures/n-plus-one-positive.pb`
  (regenerate with that scenario's `fixtures/generate.py` if missing).
- The image reachable from the **host** docker daemon for the `disclose`
  step. A successful `helm install` does not imply this: k3d nodes pull
  into the node container's containerd, and `k3d image import` side-loads
  there too, neither of which populates the host store. The scenario
  resolves the image up front with `docker image inspect`, then
  `docker pull`. When the host cannot get the image it SKIPs the disclose
  step with a warning rather than failing it.
- A default StorageClass with dynamic provisioning (already relied on by
  `daemon-ack-workflow`'s `perf-sentinel-acks` PVC).

## Known limitation

This proves the archive survives a same-node reschedule, the common case:
image bump, config change, voluntary restart. It does not exercise a
cross-node PVC reattach or a real node drain. `local-path-provisioner` on a
single-node-per-role k3d cluster does not meaningfully distinguish the two,
and that gap already exists for `daemon-ack-workflow`.

## On `cosign-verify`

Optional, and it needs **cosign 3.x**. Published charts are signed with
the Sigstore bundle format attached as an OCI 1.1 *referrer*, not as a
legacy `sha256-<digest>.sig` tag. cosign 2.x therefore answers
`no signatures found` on a chart that is perfectly signed.

That message alone cannot tell "verifier too old" from "artifact genuinely
unsigned", so the branch also checks the installed major version. Below 3
it SKIPs, naming the version. At 3 or above the same message is treated as
a real supply-chain regression and FAILs. Downgrading it to SKIP
unconditionally would let the gate certify an unsigned chart while
printing a line claiming it is signed.

The identity regex also uses `[.]` instead of `\.`. Git Bash rewrites
backslash escapes inside arguments, so the documented `\.` form arrives as
`/.` and fails with a misleading `no matching CertificateIdentity`. `[.]`
is equivalent and survives every shell.

Verified on chart 0.9.21 with cosign v3.1.2: identity
`helm-release.yml@refs/tags/chart-v0.9.21`, transparency-log entry checked.

## Counter-check

A PASS only means something if the checks can fail on the regression they
watch for. Install the same chart with persistence off and both load-bearing
assertions go red, which is the 0.2.57 shape:

```bash
helm install cdpx oci://ghcr.io/institut-du-numerique-responsable/charts/perf-sentinel --version <v> \
  -n <scratch-ns> --set fullnameOverride=cdpx \
  --set workload.kind=StatefulSet \
  --set workload.statefulset.persistence.enabled=false --wait

kubectl -n <scratch-ns> get pvc -o name | grep data-cdpx          # empty -> archive-write FAILs
kubectl -n <scratch-ns> get cm cdpx-config \
  -o jsonpath='{.data.perf-sentinel\.toml}' | grep archive.ndjson  # empty -> configmap-wiring FAILs
```

Verified on chart 0.9.21: no PVC is rendered and the ConfigMap carries no
`[daemon.archive]` path, so both checks fail as intended.
