# hub-incidents-push

**Claim.** A daemon on perf-sentinel 0.29.0 or later with `[daemon.hub_export]` and
`[daemon.incidents]` both on pushes every incident it records, closes or completes to the
Hub's `POST /api/import/incidents` (PerfSentinelHub 0.5.0 or later). An incident the
daemon's ring evicts before the Hub's next poll therefore still reaches the Hub, and so
does the end its alert resolves with.

`scenarios/hub-incidents-mirror` covers the poll path. This scenario takes the poll out of
the picture to prove the push alone.

## Setup

An isolated daemon and Hub in the scenario's own namespace, from the images the shared
pair runs (seed them with `make seed-daemon-local` and `make seed-hub-local` from the two
branches under test):

- the daemon keeps a ring of two incidents (`max_retained = 2`) and pushes to the Hub with
  a scenario-generated import key, flushing every second;
- the Hub polls once a day, and nothing in the script asks it to read the daemon, so any
  incident it holds came by push.

The pre-flight refuses a Hub that answers anything but 401 on the incident route without
a key: an older Hub would fail leg 1 for the wrong reason.

## Verdicts

| Sub-test | Passes when |
| --- | --- |
| an evicted incident still reaches the Hub | five alerts leave the daemon holding two and the Hub holding five |
| a resolve reaches the Hub | the last incident's `ended_at_ms` shows on the Hub after its alert resolves |
| nothing dropped | `perf_sentinel_hub_export_incidents_dropped_total` and `..._pending` are both 0 |

The report lands in `/tmp/scenario-hub-incidents-push-report.md`. `KEEP_NAMESPACE=yes`
keeps the isolated pair for inspection.
