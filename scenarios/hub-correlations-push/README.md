# hub-correlations-push

**Claim.** A daemon on perf-sentinel 0.30.0 or later with `[daemon.hub_export]` and
`[daemon.correlation]` both on pushes each period a correlated pair stays active, as an
episode, to the Hub's `POST /api/import/correlations` (PerfSentinelHub 0.6.0 or later). The
daemon closes an episode once the pair has not co-occurred for its gap, so a pair that fires,
falls silent and fires again is two episodes on the Hub, and an incident posted during the
second overlaps it alone.

## The pair

No shop fault endpoint reaches an isolated daemon: the collector exports to the shared daemon
only. The scenario sends the pair `correlation-event-time` already proved, with
`tools/tracegen/emit_at.py --shape n_plus_one`: an N+1 SQL trace in `corpush-order` on table
`orders`, then 1 s later in event time an N+1 SQL trace in `corpush-payment` on table
`payments`, each in its own batch. The pair the daemon reports is
`n_plus_one_sql/corpush-order` then `n_plus_one_sql/corpush-payment`.

## Setup

An isolated daemon and Hub in the scenario's own namespace, from the images the shared pair
runs (seed them with `make seed-daemon-local` and `make seed-hub-local` from the two branches
under test):

- the daemon runs `[daemon.correlation]` with a one-minute window, so the episode gap is one
  minute, freezes incidents 20 s back, and pushes to the Hub with a scenario-generated import
  key, flushing every second;
- the Hub polls once a day, so everything it holds came by push.

The pre-flight refuses a Hub that answers anything but 401 on the correlation route without a
key, and a daemon that publishes no `perf_sentinel_hub_export_correlations_pending`, since
either would fail leg 1 for the wrong reason. It also needs the Python packages of
`tools/tracegen/requirements.txt`.

## Verdicts

| Sub-test | Passes when |
| --- | --- |
| an active pair reaches the Hub | five rounds leave one open episode of the pair on the Hub |
| the daemon closes the episode after the gap | the episode carries an `ended_at_ms` and no `ended_by` within three minutes of silence |
| the second episode is the only active one | while the pair fires again, `active=true` lists the new episode alone |
| a pair active twice is two episodes | the pair's listing holds the two, the second started after the first ended |
| the incident overlaps the second episode only | the incident's window, read back from the Hub, overlaps the second episode and not the first |
| nothing dropped | `perf_sentinel_hub_export_correlations_dropped_total` and `..._pending` are both 0 |

The report lands in `/tmp/scenario-hub-correlations-push-report.md`. `KEEP_NAMESPACE=yes`
keeps the isolated pair for inspection.
