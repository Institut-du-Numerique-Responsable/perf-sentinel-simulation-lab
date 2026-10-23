# database-host-groups

Gates the `[[green.database_static.hosts]]` and `[[green.broker_static.hosts]]`
groups added in perf-sentinel 0.33.0. One instance type and one `cpu_query`
cannot describe a writer and a smaller reader, or one cluster per tenant, so a
dedicated declaration lists groups of identical hosts, each with its own
`nodes`, `instance_type` and `cpu_query`. Each group bills from its CPU, falls
back to its own ceiling and recovers on its own, and the subsystem's figure is
their sum, tagged with the declared model as soon as one group billed its
ceiling.

## Why the lab and not a unit test

The product tests the per-group arbitration against an injected clock. They
never meet the cloud scraper fetching several probes on one tick, one of them
going silent while the others keep answering, then coming back with a reading
that reaches back over the outage. This scenario is the only place those
coexist.

## Legs

| Leg | What it asserts |
|-----|-----------------|
| D1 | A group without `instance_type` is refused, naming `hosts[1]`. |
| D2 | Two groups on one `cpu_query` are refused by index, and the error never echoes the query. |
| D3 | `hosts` next to a top-level `nodes` is refused. |
| D4 | `hosts` under `placement = "shared"` is refused. |
| D5 | `hosts` next to `[green.alumet.database]` is refused. |
| D6 | A section without `hosts` still loads. |
| G1 | Both groups live: `cloud_specpower`, database power equal to each group's SPECpower envelope at its CPU, summed. The age gauge stays under the staleness. |
| G2 | The reader's query answers an empty vector: the figure turns `database_specpower` while the writer keeps its reading, so the power is writer live plus reader ceiling, not two ceilings. The age gauge reads the silent group. |
| G3 | The reader comes back: `cloud_specpower` again, and the energy over the outage and recovery is billed once. A reading stacked on the ceiling would add the reader's live power over the whole outage. |
| B1 | Broker groups next to database groups: `messaging_waste` on `cloud_specpower`, broker power equal to its groups' envelope. |

Powers are read as the slope of `perf_sentinel_scored_database_energy_kwh_total`
and `perf_sentinel_scored_broker_energy_kwh_total` over 20 s, within 12
percent. The alternative each leg must exclude sits 24 percent or more away.
The watts come from the embedded SPECpower table, and the script refuses to run
when those rows move.

## Prerequisites

Self-contained: a local release binary (`cargo build --release -p
perf-sentinel` in `PERF_SENTINEL_REPO_PATH`), `python3` and `curl`. A python
stand-in answers the Prometheus `/api/v1/query` endpoint per query from a state
file, and the traffic goes to the daemon's JSON socket. No cluster, no Docker.

```bash
make verify-database-host-groups
```

About 2 minutes. Report: `/tmp/scenario-database-host-groups-report.md`.
