# limit-trace-shapes

Adversarial trace shapes against the committed daemon, at low rate through
the port-forward: one trace with 1500 spans (over `max_events_per_trace`),
a 400-deep parent chain, a 1200-sibling fanout, duplicate trace ids
re-emitted after the TTL, and a 70 KB SQL statement (over the 64 KiB cap).

## Run

```bash
make verify-limit-trace-shapes
```

Requires the daemon at 0.8.7+ (`scripts/seed-daemon-local.sh` before the
release image exists) and `opentelemetry-proto` on the host python3.

## Asserts

- The ring-buffer drop above `max_events_per_trace` moves
  `perf_sentinel_trace_events_dropped_total` by exactly 3 x (1500 - cap), and
  `/api/export/report` carries the tuning warning naming the cap (0.47.0+).
- Zero pod restarts across all five shapes, RSS at the end under 200 MiB
  (the pod limit is 256Mi).
- Deep chains ingest without a latency cliff, all spans received.
- The wide fanout produces an `excessive_fanout` finding.
- Both generations of duplicate trace ids are analyzed (double-count by
  design, documented in the upstream LIMITATIONS).
- Huge SQL flows through truncated, `/api/export/report` stays bounded.

## Known feedback items

- Duplicate trace ids across the TTL are double-counted by design.
