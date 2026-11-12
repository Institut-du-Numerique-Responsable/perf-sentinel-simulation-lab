# daemon-analysis-shedding

Validates the **decoupled analysis worker** and its **metered load-shedding**,
both new in perf-sentinel **0.8.6**.

## What 0.8.6 changed

Before 0.8.6 the daemon ran `detect + score` inline on the `select!` loop, so a
slow analysis pass stalled OTLP ingestion and TTL eviction. 0.8.6 moves that
CPU-heavy path onto a **single analysis worker behind a bounded channel**
(`[daemon] analysis_queue_capacity`, default 1024). Under sustained overload the
daemon now **sheds whole analysis batches** rather than blocking ingestion, and
the shedding is **metered, never silent**:

| metric | type | meaning |
|---|---|---|
| `perf_sentinel_analysis_queue_depth` | gauge | batches waiting in the worker queue |
| `perf_sentinel_analysis_shed_batches_total` | counter | batches shed (queue full or worker stopped) |
| `perf_sentinel_analysis_shed_traces_total` | counter | traces inside the shed batches |

The ingest path has its own bounded channel
(`[daemon] ingest_queue_capacity`, default 1024). Both are range-validated to
`1..=1048576`.

## How the scenario forces shedding deterministically

The 0.8.6 worker is efficient: at its committed 500m CPU limit it keeps up
with the lab's realistic traffic (`validate-findings`, ~250 traces/s) without
shedding, a positive sign the decoupling works. Forcing the safety net to
engage needs both a **tiny queue** and **non-trivial traces**, since trivial
single-span traces are scored in microseconds and never back the queue up:

- a **scoped ConfigMap** sets `analysis_queue_capacity = 1` (reduced from
  1024) and `max_active_traces = 20` (small window). No CPU throttling: the
  daemon stays at 500m, and the small queue is the lever.
- the scenario replays a committed OTLP payload, **`fixtures/shed-load.pb`**:
  300 distinct N+1 traces (one HTTP root + six SQL children sharing a
  template but differing in their bound id literal), concurrently from
  `PARALLELISM` injectors. Each request overflows the 20-slot window into a
  ~280-trace eviction batch. The batches arrive faster than the single worker
  drains the real detect+score, so whole batches are shed.

`telemetrygen` is deliberately **not** used: perf-sentinel's ingest parser
keeps a span only if it carries an I/O attribute (`db.statement`/`http.url`),
and telemetrygen's generic spans ingest as zero events. The fixture is
therefore hand-built (see `fixtures/generate.py`, needs
`opentelemetry-proto`). `verify.sh` replays the committed `.pb` with `curl`,
the same pattern as `daemon-sigterm-drain`.

## Assertions

1. **Surface present**: the three shed metrics are registered on `/metrics`
   (a 0.8.6-only surface; absence means the daemon is not 0.8.6).
2. **Range validation**: the local 0.8.6 binary rejects
   `analysis_queue_capacity = 0` with `analysis_queue_capacity must be >= 1`
   (skipped in CI, where the host binary is absent).
3. **Metered shedding fires**: `analysis_shed_batches_total` climbs > 0 and
   `analysis_shed_traces_total` climbs `>= shed_batches` (~300 traces per
   shed batch. Nothing is lost uncounted).
4. **Ingestion not blocked**: `otlp_spans_received_total` climbs by hundreds of
   thousands during the flood and the daemon stays reachable. This is the
   core regression the worker decoupling prevents.
5. **Daemon survives**: the pod `restartCount` is unchanged (no OOM under the
   flood. The shared-signature N+1 keeps the findings store tiny).

## Why analysis_queue_capacity is the lever

`analysis_queue_capacity` sets the **overload threshold**. At `cap = 1`
shedding is deterministic at modest concurrency, which is what this scenario
gates on. A larger cap raises the bar, but it is not a hard wall: a heavy
enough flood sheds at the default `1024` too (confirmed during validation).
The point validated here is the metered-shed *path* plus the *configurability
and range-validation* of the knob, not that `1024` is immune.

## Fail-loud (not runtime-triggered here)

If the analysis worker dies (e.g. a detector panics), the daemon exits non-zero
(`DaemonError::AnalysisWorkerStopped`) so a supervisor restarts it, instead of
standing up while analyzing nothing. This is covered by upstream unit tests
(`crates/sentinel-core/src/daemon/{mod,event_loop}.rs`). The lab has no safe
lever to panic a detector mid-flight, so this path is asserted statically.

## Run

```bash
make verify-daemon-analysis-shedding
# tunables: SHED_CAP, SHED_WINDOW, PARALLELISM, ROUNDS
```

The report lands at `/tmp/scenario-daemon-analysis-shedding-report.md`. The
scenario restores the committed daemon ConfigMap (default queue capacities,
`max_active_traces=10000`) on exit.
