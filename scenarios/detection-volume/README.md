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
