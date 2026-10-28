# hub-detection-volume

PerfSentinelHub 0.8.6 stores the detection ledgers of perf-sentinel 0.37.0
daemons and serves, on a windowed `GET /api/findings`, how many times each
finding was detected, with whether that count is complete and why not.

## Why it exists

The engine side is proven by `detection-volume`, the Hub side by its unit
tests, and neither sees the other. This scenario is the seam: real 0.37.0
daemons, a real Hub process, the poll and the push both carrying ledgers, a
restart, and two daemons behind one address.

## What it asserts

A local Hub knows three sources, and both daemons receive the same N+1
(service `hdv-planted`), so the Hub holds one signature:

| source | reaches |
|--------|---------|
| `hdv-poll` | daemon A, polled directly, no push |
| `hdv-push` | daemon B, which pushes to the Hub. Its `BaseUrl` is a closed port, so nothing is polled |
| `hdv-pods` | daemons A and B behind a loopback proxy that moves to the other daemon on each `/api/status`, two pods behind one Service |

| id | assertion |
|----|-----------|
| H1 | each daemon counts the same 8 detections itself, and `hdv-poll` (poll alone) and `hdv-push` (push alone) both serve exactly 8 |
| H2 | daemon A restarts (a new `ledger_id`) and takes 5 more: its own ledger counts 5, the Hub serves 13 for `hdv-poll`, with `restart` in `detections_gaps`, `detections_complete: false`, and no `multi_instance` for two successive ledgers |
| H3 | `hdv-pods` reads two ledgers alive at once and carries `multi_instance`, `hdv-push` does not |
| H4 | the finding's `detections` is the sum of its sources, and incomplete |
| H5 | the same finding read without `from` or `to` carries none of the seven new names |
| H6 | `perf_sentinel_hub_detection_reads_total{source="hdv-poll",outcome="ok"}` is above 0 on `/metrics` |

`hub-derived-status` needed no change for the Hub's `last_seen` fix: it pushes
its envelopes with `stored_at_ms` at the push time, which is the time the Hub
used before.

## Run

```bash
cd ~/RiderProjects/PerfSentinelHub && dotnet build PerfSentinelHub.sln -c Release
make verify-hub-detection-volume

# Another Hub build or daemon binary:
PERF_SENTINEL_HUB_DLL=/path/to/PerfSentinelHub.dll \
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel make verify-hub-detection-volume
```

The Hub runs as a local `dotnet` process from a Release build, the daemons
from the local perf-sentinel binary. python3 with `opentelemetry-proto`, curl.
No cluster, no Docker, no outbound call (`Hub:UpdateCheck` is off). Ports
14960 to 14966 (`HDV_BASE_PORT`). About 90 seconds, most of it the daemon's
detection push, at most once a minute. `KEEP_TMP=yes` keeps the logs. Report
at `/tmp/scenario-hub-detection-volume-report.md`.

The scenario SKIPs with exit 0, rather than failing, when the daemon binary, the Hub
build, `dotnet` or `opentelemetry-proto` is absent. A port already answering is a
failure.

## What it found (2026-10-28)

On Hub 0.8.5, H1 FAIL: the windowed read carries no `detections`. On the
0.8.6 release branch with the 0.37.0 daemons, PASS: 8 by poll and 8 by push,
13 over the restart with `[open_day, restart]`, `hdv-pods` with
`[multi_instance, open_day, restart]`.
