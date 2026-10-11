# daemon-sigterm-drain

Prove the **v0.8.5 graceful-drain-on-SIGTERM** contract: the daemon now flushes
its in-flight streaming window through detection on `SIGTERM` (Unix), not only
on `SIGINT`. A normal Kubernetes pod termination (rolling update, scale-down,
node drain, all of which deliver `SIGTERM`) therefore **keeps** the current
window instead of dropping it. Only an ungraceful kill (`SIGKILL` after the
grace period, OOM) still loses it.

## Use case

Before 0.8.5 only `SIGINT` (Ctrl+C) triggered the drain, so
`kubectl rollout restart` / `kubectl delete pod` / a scale-down, all `SIGTERM`,
lost the in-flight window. v0.8.5 routes the event loop through
`crate::shutdown::shutdown_signal()`. That function resolves on `SIGINT`
**and** `SIGTERM`, and runs the same `drain_all()` + detection cleanup for
either. This scenario is the lab's proof of that behavior.

It complements
[`failure-mode-daemon-restart`](../failure-mode-daemon-restart/), whose
"in-flight spans may be lost (graceful drop)" wording encodes the **old**
contract. Under 0.8.5 that wording now applies specifically to `SIGKILL` /
over-grace-period kills, not to a graceful `SIGTERM`.

## Why a before/after test with two controls

A finding appearing after a graceful shutdown is only meaningful if we also show it
does **not** appear without the drain. So the scenario runs a positive and a
negative control reading the **same** surface (apples-to-apples):

- **Positive control**: graceful `SIGTERM` (`kubectl scale --replicas=0`, the
  scale-down path): the in-flight N+1 is flushed to the per-window NDJSON
  archive.
- **Negative control**: ungraceful `SIGKILL` of the daemon process (`kill -9`
  on its k3d node, modelling OOM / over-grace kill): the in-flight N+1 is lost,
  never archived. This is what makes the positive result attributable to the
  drain and not to a TTL finalization that would have happened anyway.

### Capture surface

The opt-in per-window NDJSON archive (`[daemon.archive]`), written to the writable
`perf-sentinel-acks` PVC mount (the rootfs is read-only). Upstream `LIMITATIONS.md`
calls this archive "the one place a gap is visible" on an ungraceful kill, so it is
the natural before/after surface. After the daemon pod is gone, a read-only reader
pod mounts the same PVC and counts the lines carrying the control's marker.

### Timing subtlety

With the committed `trace_ttl_ms = 5000`, a trace finalizes through detection
~5 s after its last span by TTL eviction alone, so a `SIGTERM` landing after
that would archive the finding even without the drain. The scenario therefore
raises `trace_ttl_ms` to **30000** in a scenario-scoped ConfigMap and triggers
the signal seconds after injection, so the trace is genuinely **in-flight** (no
TTL eviction) when the signal lands. The committed config is restored at
cleanup.

### Why a real N+1, not telemetrygen

`telemetrygen` emits generic spans with no SQL semantics, so it cannot form an N+1.
The scenario injects two pre-encoded OTLP/protobuf fixtures (the daemon's OTLP HTTP
receiver only accepts `application/x-protobuf`), each a single trace of six SQL
child spans sharing one normalized template with distinct bound ids
(`SELECT * FROM <table> WHERE id = 1..6`). Six distinct param sets over one template
clears `n_plus_one_min_occurrences = 5` via the detector's direct rule. The two
fixtures use distinct `service.name` / table markers (`probe_positive` /
`probe_negative`) so the controls never alias in the shared archive. See
[`fixtures/generate.py`](fixtures/) for provenance.

## Sequence

```
setup   apply committed manifest (baseline) -> scoped ConfigMap (ttl=30000 + archive)
        set daemon image to $SIGTERM_DRAIN_IMAGE ; create injector ns + NetworkPolicy pair
positive  reset archive -> scale 1 -> inject probe_positive (in-cluster Job, OTLP/protobuf)
          scale 0 (graceful SIGTERM) -> reader counts probe_positive lines  (expect >= 1)
negative  reset archive -> scale 1 -> inject probe_negative
          kill -9 daemon PID on its node (SIGKILL) -> scale 0 -> reader counts (expect 0)
sanity    scale 1 -> /api/status answers, no panic/FATAL in logs, ingestion resumes
cleanup   re-apply committed manifest (image+config+grace) ; rm archive ; drop ns + NetworkPolicy
```

## Inputs

| Variable              | Default                   | Notes                                                            |
|-----------------------|---------------------------|------------------------------------------------------------------|
| `SIGTERM_DRAIN_IMAGE` | the manifest's current daemon pin | daemon image under test (defaults to the version under validation); set a 0.8.4 image for the counter-check |
| `DAEMON_LOCAL_PORT`   | `14318`                   | host port from `scripts/port-forward.sh`                         |
| `INJECT_IMAGE`        | `curlimages/curl:8.11.1`  | in-cluster OTLP/protobuf POSTer                                  |
| `PVC_UTIL_IMAGE`      | `busybox:1.37`            | archive reset / reader pod image                                 |
| `SCALEDOWN_TIMEOUT`   | `90`                      | seconds to wait for the daemon pod to terminate                  |
| `KEEP_NAMESPACE`      | `no`                      | `yes` skips cleanup (debugging)                                  |

## Verdict

PASS when all three hold:

- **positive**: `probe_positive` archived windows ≥ 1 (graceful SIGTERM drained),
- **negative**: `probe_negative` archived windows = 0 (ungraceful SIGKILL lost it),
- **sanity**: daemon `/api/status` answers, no `panic`/`FATAL` in `--since=5m` logs,
  ingestion resumes (`active_traces` > 0 after a post-recovery injection).

FAIL writes the per-control counts and verdicts into `/tmp/scenario-daemon-sigterm-drain-report.md`.

## Counter-check (proves the test measures the new behavior)

Run the same scenario against a 0.8.4 image and the **positive control must fail**
(0.8.4 does not drain on `SIGTERM`, so `probe_positive` is never archived):

```
SIGTERM_DRAIN_IMAGE=ghcr.io/institut-du-numerique-responsable/perf-sentinel@sha256:<0.8.4-digest> \
  ./scenarios/daemon-sigterm-drain/verify.sh   # -> FAIL on the positive control
```

## Runtime prerequisites

- Lab bootstrap done: `make up-cni && make seed-services`.
- A `0.8.5+` daemon image. By default the scenario scrapes the current pin from
  `manifests/perf-sentinel-daemon.yaml`, so it exercises the version under
  validation (including a `make seed-daemon-local` pre-release pin) with no
  extra setup. Pass `SIGTERM_DRAIN_IMAGE` explicitly to target another image.
- `docker` CLI access to the k3d nodes (used for the node-level `SIGKILL`).
- Daemon port-forward handled by the scenario via `scripts/port-forward.sh`.
