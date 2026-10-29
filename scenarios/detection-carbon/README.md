# detection-carbon

The 0.38.0 detection ledger carries each day's avoidable carbon, so
PerfSentinelHub can turn a finding's I/O into grams.

## Why it exists

The ledger of 0.37.0 counts detections, never grams. 0.38.0 adds four keys
to each `days` object of `GET /api/detections` and of the push to the Hub
(`POST /api/import/detections`): `avoidable_gco2` and `avoidable_gco2_low`,
the day's sums of `green_summary.co2.avoidable.mid` and `.low`, then
`avoidable_io_ops` and `total_io_ops`. Every scored batch feeds them, a batch
with no finding included, which adds to `total_io_ops` only. The Hub reads
`avoidable_gco2 / avoidable_io_ops` as the day's grams per avoidable I/O
operation. The four keys are present together or absent together, absent
when green scoring is off.

## What it asserts

A throwaway loopback daemon runs with `[green] enabled = true` and
`default_region = "eu-west-3"`, and pushes to a fake PerfSentinelHub that
records every POST.

| id | assertion |
|----|-----------|
| C1 | after 3 traces with an N+1, today's day object carries the four keys, with `avoidable_gco2 > 0`, `avoidable_io_ops > 0`, `total_io_ops >= avoidable_io_ops` and `0 <= avoidable_gco2_low <= avoidable_gco2` |
| C2 | `avoidable_gco2 / avoidable_io_ops` is finite and positive |
| C3 | 4 clean traces (two SELECTs on two tables, no finding) raise `total_io_ops` and leave the three avoidable sums unchanged |
| C4 | the push carries the four keys on today's day object, with the API's values |
| C5 | 4 more clean traces, a carbon-only change, make the acknowledged day dirty: the next regular round resends it with the larger `total_io_ops` and no count row |
| C6 | a second run with no `[green]` section and the same N+1 traces has none of the four keys, in the API and in the drain push |

C5 waits for the regular round, at least a minute after C4's push, instead
of a SIGTERM: the drain flags today a gap, which would dirty the day on its
own and prove nothing about the carbon.

The payloads are built at run time with `opentelemetry-proto`, span
timestamps at the current time.

## Run

```bash
cd ~/RustroverProjects/perf-sentinel && cargo build --release -p perf-sentinel
make verify-detection-carbon

# Another binary:
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel make verify-detection-carbon
```

Local release binary, python3 with `opentelemetry-proto`, curl. No cluster,
no Docker, about two minutes and a half. Ports 14950, 14951 and 14952
(`DC_DAEMON_HTTP_PORT`, `DC_DAEMON_GRPC_PORT`, `DC_HUB_PORT`). Report at
`/tmp/scenario-detection-carbon-report.md`.

## What it found (2026-10-29)

On 0.37.1, C1 FAIL by construction: the day object has no carbon key, so the
check stops on the first missing one. No 0.37.1 binary was at hand to run
it. On 0.38.0, PASS: 3 N+1 traces give `avoidable_gco2` 3.45e-05 g, low
1.725e-05 g, 15 avoidable I/O out of 18, so 2.3e-06 g per avoidable
operation. The clean batch takes `total_io_ops` from 18 to 26 and moves
nothing else. The second clean batch (26 to 34) was resent 61 s after the
first push, with no count row. The green-off run shows none of the keys.
