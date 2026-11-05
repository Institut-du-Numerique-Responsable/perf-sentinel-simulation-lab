# memory-guard-band-release

The `[daemon] memory_high_water_pct` guard of perf-sentinel 0.42.1, read from a
real cgroup v2 limit on a throwaway container of the image under test.

## Why it exists

On a production daemon with an 85% mark on a 1 GiB limit, the working set parked
at 80.7%, above the 80% resume point, and every span was refused for 16 hours
until a rollout restarted the pod. 0.42.1 clears the flag after 60 seconds inside
the hysteresis band, or one `trace_ttl_ms` when that is longer. The engine's unit
tests feed the state machine ratios by hand, so nothing else exercises the path
from `memory.current` and `memory.max` to the gauge and the 503.

`docker update --memory` moves `memory.max` live, which places the ratio above
the mark, inside the band or below it on demand, with no load generator. The
mark is 85, so the band runs from 80 to 85.

## What it asserts

| id | assertion |
|----|-----------|
| I1 | below the mark the gauge reads 0 and an OTLP export answers 200 |
| C1 | above the mark the gauge reads 1 within 5 seconds |
| C2 | an OTLP export answers 503 |
| C3 | `perf_sentinel_otlp_rejected_total{reason="memory_pressure"}` grew by 1 |
| P1 | a ratio parked above the mark stays rejected for 75 seconds, with no release warning |
| B1 | a ratio parked inside the band releases after 55 to 75 seconds |
| B2 | the warning `memory working set held at` fires once and names a ratio inside the band |
| B3 | an OTLP export answers 200 again |
| R1 | crossing the mark again sets the gauge |
| R2 | falling below the resume mark clears the gauge within 5 seconds |
| R3 | that recovery logs no release warning |
| O1 | a ratio alternating between 87% and 83% every 5 seconds still releases |
| T1 | with `trace_ttl_ms = 90000` the hold lasts 85 to 105 seconds |
| T2 | the warning of that release names `90s` |

The working set of an idle daemon is about 20 MiB, so one 2 MiB allocator step
moves the ratio by 10 points, out of the band, and the guard then rightly keeps
rejecting. The script waits a minute after start and re-pins the ratio every 5
seconds during a hold. Without that, B and T fail on a sound daemon, observed on
2026-11-05.

Against 0.42.0 the export still answers 503 after 91 seconds in the band, and
B1, B2, B3, O1, T1 and T2 fail, observed on 2026-11-05.

## Prerequisites

- Docker with cgroup v2, `curl`, `python3`.
- Port 15441 free on loopback (`PORT` overrides it).
- The image resolves through `scripts/resolve-image.sh`.

## Run

```bash
make verify-memory-guard-band-release
# or
./scenarios/memory-guard-band-release/verify.sh
```

About 9 minutes. Report: `/tmp/scenario-memory-guard-band-release-report.md`.
