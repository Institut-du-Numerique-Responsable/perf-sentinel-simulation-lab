# detection-volume

The 0.37.0 detection ledger counts every detection of a finding, past the
findings ring, and starts over on each daemon start.

## Why it exists

The `seen_count` of `/api/findings` counts the detections the daemon's ring
still retains, 10,000 entries shared by every finding and lost on restart.
Nobody could say how many times a finding happened. 0.37.0 adds a per-day
ledger, served on `GET /api/detections`, that counts each detection by
signature before the ring sees it, and `/api/status` gains a
`detection_ledger` object. The ledger is in memory only: each start opens a
new one, whose first day is a gap.

## What it asserts

A throwaway loopback daemon with `max_retained_findings = 5` receives one
OTLP/protobuf POST: 12 traces with the same N+1 (service `dv-planted`), then
6 traces with an N+1 each on its own service, 7 signatures for a ring of 5.

| id | assertion |
|----|-----------|
| V1 | `/api/detections` counts the planted signature 12 times, on one row, while the ring retains fewer than 12 of its detections |
| V2 | a walk with `limit=1` and the `next_after` cursor returns the same rows, so the same total |
| V3 | `/api/status` `detection_ledger.current_day` is today, the UTC epoch day |
| V4 | after a SIGTERM and a new start: a new `ledger_id`, today carries `gap = true`, and the planted signature is gone |
| V5 | the push to a fake PerfSentinelHub on loopback (`POST /api/import/detections?source_id=dv-lab`) carries the 12 planted detections and a day object |
| V6 | 3 more planted detections posted just before the SIGTERM reach the fake Hub: only the drain's forced push can carry them, the next regular round being a minute away |
| V7 | 0.50.0: one N+1 of service `dv-split` in two namespaces (4 traces in `dv-ns-a`, 2 in `dv-ns-b`). `?split=grouping` answers `"split": "grouping"` and one row per grouping, 4 and 2, while the unsplit route answers one ungrouped row of 6 |
| V8 | a `limit=1` walk of the split ledger, passing `next_after` and `next_after_grouping` back, returns the rows of the single split page |
| V9 | the push of the first ledger goes to `/api/import/detections/by-grouping` only, with `"split": "grouping"` and the two grouping rows |
| V10 | after the restart, the fake Hub answers `404` on the split route, like a Hub that predates it: the new ledger's split pages are refused, then the push goes to `/api/import/detections` with one ungrouped `dv-split` row of 6 |

The payload is built at run time with `opentelemetry-proto`, span timestamps
at the current time.

## Run

```bash
cd ~/RustroverProjects/perf-sentinel && cargo build --release -p perf-sentinel
make verify-detection-volume

# Another binary, a different load:
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel DV_PLANTED=40 make verify-detection-volume
```

Local release binary, python3 with `opentelemetry-proto`, curl. No cluster,
no Docker. Ports 14948 and 14947 (`DV_DAEMON_HTTP_PORT`,
`DV_DAEMON_GRPC_PORT`). Report at `/tmp/scenario-detection-volume-report.md`.

## What it found (2026-10-28)

On 0.36.0, V1 FAIL: `GET /api/detections` answers 404. On the 0.37.0 branch,
12 detections on one row while the ring retains 0 of them, 7 pages of one
row each, and a new ledger with today as a gap after the restart.

## What it found (2026-11-24)

On 0.49.0, V7 FAIL: `?split=grouping` answers the unsplit page, without
`"split"`. On the 0.50.0 branch, the `dv-split` N+1 gives rows of 4 and 2 per
namespace and one row of 6 unsplit, the walk of 9 one-row pages returns them,
the push takes `/by-grouping` only, and after the restart the fake Hub's `404`
there sends the new ledger to `/api/import/detections` with one row of 6.
Since 0.50.0 pushes on the split route first, `detection-carbon` and
`card-signal` read the detection pages of either route.
