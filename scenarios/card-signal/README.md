# card-signal

The 0.39.0 daemon counts the runs of a watched threshold-type finding that
stayed at or under its threshold, so PerfSentinelHub can tell "fixed and
still running" from "no longer seen" before it offers a share card in its
threshold form.

## Why it exists

A slow, fanout, chatty, pool or serialized finding that stops being detected
may be fixed, or may no longer run. 0.39.0 lets the Hub ask: the reply to the
detection push (`POST /api/import/detections`) may carry
`{"accepted":..,"rejected":..,"watch":[signatures]}`. For each watched
threshold-type signature, the daemon counts per day the runs at or under the
threshold, a span for `slow_*`, as `below_threshold_passes` on the count rows
of `GET /api/detections` and of the push. A watched signature gets a row even
with `detections: 0`. Each `days` object gains `thresholds`, the slow,
fanout, chatty, pool and serialized thresholds the daemon applied. No `watch`
from the Hub means nothing is counted, and the list lives in memory only, so
a restart loses it until the next accepted push reply (docs/QUERY-API.md,
docs/CONFIGURATION.md `[daemon.hub_export]`, docs/LIMITATIONS.md).

## What it asserts

A throwaway loopback daemon runs with `slow_query_threshold_ms = 250` and the
other four thresholds off their defaults (`max_fanout = 30`,
`chatty_service_min_calls = 25`, `pool_saturation_concurrent_threshold = 12`,
`serialized_min_sequential = 4`). It pushes to a fake PerfSentinelHub whose
detection route answers the status and the `watch` list a mode file sets.
Every run first posts an N+1 on another service (`cs-anchor`), so the day
moves and a detection push happens.

| id | assertion |
|----|-----------|
| S1 | run 1, the Hub replies without `watch`: one trace with 3 SELECTs of one template at 400 ms gives one `slow_sql:cs-planted:...` signature, the one to watch |
| S2 | run 1, after an accepted reply without `watch`: 4 traces with that template at 100 ms and at exactly 250 ms (8 runs) give no `below_threshold_passes`, in the API and in the drain push |
| S3 | run 2, the Hub replies `watch: [S1]`: the same 8 runs give today's row for S1 with `detections: 0` and `below_threshold_passes: 8` (one per span, the one at the threshold included) |
| S4 | today's `thresholds` is exactly `{"slow_query_threshold_ms":250,"slow_http_threshold_ms":250,"max_fanout":30,"chatty_threshold":25,"pool_saturation_threshold":12,"serialized_min_calls":4}` |
| S5 | the regular push of run 2 carries the S3 row and the S4 thresholds |
| S6 | run 3 after a SIGTERM and a new start, the Hub answering 503 on the detection route: the push reached it, 8 more runs give no row for S1 |
| S7 | run 3, the Hub accepts again with `watch: [S1]`: 8 more runs give `detections: 0`, `below_threshold_passes: 8` |

S6 uses a 503 rather than a missing push: the restarted daemon talks to the
Hub at once, so only a reply it does not accept keeps the list away long
enough to show it was not carried over the restart.

The payloads are built at run time with `opentelemetry-proto`, span
timestamps at the current time.

## Run

```bash
cd ~/RustroverProjects/perf-sentinel && cargo build --release -p perf-sentinel
make verify-card-signal

# Another binary:
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel make verify-card-signal
```

Local release binary, python3 with `opentelemetry-proto`, curl. No cluster,
no Docker, about a minute and a half (S5 waits for the regular round, at
least a minute after the first push). Ports 14953, 14954 and 14955
(`CS_DAEMON_HTTP_PORT`, `CS_DAEMON_GRPC_PORT`, `CS_HUB_PORT`). Report at
`/tmp/scenario-card-signal-report.md`.

## What it found (2026-10-30)

On 0.38.0, S3 FAIL by construction: the reply's `watch` is ignored, so S1
gets no row. No 0.38.0 binary was run. On 0.39.0, PASS in 82 s: the watched
signature `slow_sql:cs-planted:_api_orders:d38d7a7c...` reads
`detections: 0`, `below_threshold_passes: 8`, the span at exactly 250 ms
counted, with `extra_io_ops: 0` since green scoring is on by default. The
thresholds carry the five configured knobs, the slow one under both slow
keys. The regular push carried the day's thresholds on page 0 and the row on
page 1. After the restart the 503 reply left the list empty, and the next
accepted reply brought the 8 passes back. No disagreement with the docs.
