# limit-saturation-curve

Ramps traces/sec (50 to 1600, `LONG_RUN=1` extends to 3200) against the
committed daemon config and produces the saturation table operators size
deployments with: per-step mean events/s, max queue depth, shed and
channel_full deltas, max RSS, and the derived "max clean throughput at
256Mi/500m".

## Run

```bash
make verify-limit-saturation-curve
```

Raw samples land in `/tmp/limit-saturation-curve/saturation.tsv`. The
derived table is embedded in the scenario report.

## Asserts

- The ramp eventually trips shedding or channel_full (the limit was found).
- Ingestion (OTLP spans received per second) never stalls to zero while shedding.
- Daemon answers >= 70% of polls, zero restarts (no OOM), RSS <= 256 MiB.
