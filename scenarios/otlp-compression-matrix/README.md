# otlp-compression-matrix

Every transport × encoding combination an OTLP exporter can put on the wire,
checked against the daemon under test and against the last release that
carried the bug.

## Why this scenario exists

Up to and including 0.9.26 the daemon's OTLP gRPC listener mounted its
`TraceServiceServer` without ever calling `accept_compressed`. The OTel
Collector's OTLP exporter gzips **by default**, so tonic answered
``rpc error: code = Unimplemented desc = Content is compressed with `gzip`
which isn't supported``. The Collector treats `Unimplemented` as permanent and
drops each batch without retrying. Cluster-side that is a total, silent loss of
telemetry: the pod stays `Ready`, `/health` answers, every `/metrics` counter
stays at zero, and the outage exists only in the Collector's logs.

**The lab ran for months without catching it**, for two compounding reasons:

1. The lab's collector targets the daemon over `otlphttp/perf_sentinel`
   (`helm/values/otel-collector.yaml`): HTTP on `:14318`, never gRPC.
   The HTTP endpoint has decompressed gzip since 0.5.5, so that path was
   always green.
2. The only lab producers that speak gRPC to a perf-sentinel listener are
   `tracegen.py --protocol=grpc` (`limit-multi-source`) and `telemetrygen`
   (`java-ci-capture`), and **neither compressed**. The lab therefore had a gRPC
   path and a compressed path, but never both at once.

This scenario closes that gap, and keeps HTTP covered so neither transport is
traded for the other.

## Legs

| leg | transport | encoding | producer | daemon | expected |
|---|---|---|---|---|---|
| A | gRPC | gzip (exporter default) | Collector | under test | ingested, findings produced, no `Unimplemented` |
| B | gRPC | gzip (exporter default) | Collector | **baseline** | 0 spans + `Unimplemented` in the Collector log |
| C | gRPC | none | Collector | under test | ingested |
| D | HTTP | gzip (exporter default) | Collector | under test | ingested |
| E | HTTP | none | Collector | under test | ingested |
| F | HTTP | deflate | tracegen | under test | ingested (new in 0.9.28) |
| F′ | HTTP | deflate | tracegen | **baseline** | refused |
| G | gRPC | deflate | tracegen | under test | ingested (new in 0.9.28) |
| H | gRPC | zstd, then snappy | Collector | under test | refused with `Unimplemented`, as `docs/INSTRUMENTATION.md` states |
| I | gRPC | gzip (exporter default) | **cluster Collector** | manifest pin | findings on a real N+1 burst, then revert |

Leg B is the point of the scenario. Without it, a green A cannot tell
"fixed" from "never exercised", which is exactly how the bug survived.

Legs F and G go through tracegen's native grpcio/http client because the
Collector's gRPC exporter offers gzip, snappy and zstd only: deflate is
unreachable from it, and the lab's own client is the only way to exercise the
encoding the daemon now advertises.

## Prerequisites

Legs A-H are **self-contained**: Docker only. No cluster, and no local
binary, because the A/B needs a *published* baseline image, not a build.
Leg I needs a running cluster with `make seed-services` done. It SKIPs
cleanly otherwise.

`lab-tracegen:1` is built on the fly if absent (`docker build tools/tracegen`),
without the k3d import that `scripts/seed-tracegen.sh` performs.

## Run

```bash
make verify-otlp-compression-matrix
```

Knobs:

- `PERF_SENTINEL_IMAGE` / `PERF_SENTINEL_VERSION`: the image under test.
  Defaults to the pin in `manifests/perf-sentinel-daemon.yaml` via
  `scripts/resolve-image.sh`.
- `BASELINE_IMAGE`: the counter-proof image, default
  `ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.9.26`. It must be a build that
  predates the fix, otherwise legs B and F′ fail by design.
- `TRACES`, `COLLECTOR_IMAGE`, `DAEMON_HTTP_PORT`, `COLLECTOR_HTTP_PORT`,
  `COLLECTOR_HEALTH_PORT`.

Report: `/tmp/scenario-otlp-compression-matrix-report.md`.

## Notes

- Leg I mutates the shared cluster collector through a Helm overlay. The revert
  is armed **before** the upgrade and runs from the EXIT trap, the same
  discipline as `batch-otlp-file`. After a run, confirm with
  `helm -n observability get values otel-collector` that
  `otlphttp/perf_sentinel` is back.
- `retry_on_failure` is disabled in the throwaway collector config so a
  permanent refusal settles immediately instead of sitting in a queue while the
  counters are read.
- zstd and snappy stay refused on purpose: they would pull `zstd-sys` (C
  bindings) into a static musl binary. gzip and deflate both resolve to
  `flate2`, already present through `tower-http`.
