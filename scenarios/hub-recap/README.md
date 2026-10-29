# hub-recap

PerfSentinelHub 0.9.0 turns the detection volume and the day carbon of
perf-sentinel 0.38.0 daemons into a review recap: priorities priced in CO2,
actions with an owner, business labels, and frozen reports a subscription
delivers by signed webhook and by e-mail.

## Why it exists

The engine side is proven by `detection-carbon`, the Hub side by its unit tests
with a fake SMTP relay and a fake daemon, and neither sees the other. This
scenario is the seam: a real 0.38.0 daemon scoring carbon pushes to a real Hub
process, the recap prices the planted N+1 at the daemon's own coefficient, and
the reports leave the Hub through a real webhook POST and a real SMTP session.

## What it asserts

A local Hub knows one source, `hrc-lab`, which only the daemon's push feeds (its
`BaseUrl` is a closed port). The daemon (`[green] enabled = true`,
`default_region = "eu-west-3"`) receives 8 N+1 traces on `/api/orders` and 8 on
`/api/invoices`, service `hrc-shop`. The Hub restarts twice on the same
database: phase 1 trusts `X-Forwarded-User` (`Hub:AckRelay:TrustIdentityHeader`),
phase 2 adds a daily subscription, phase 3 turns access control on with two
local accounts.

| id | assertion |
|----|-----------|
| R1 | today's tech recap (`period=day`) ranks the `/api/orders` N+1 with `volume_known`, the daemon's own `extra_io_ops` as `avoidable_io_ops`, `co2_partial: false`, no `co2_missing_reason`, and `co2_grams` equal to extra I/O x `avoidable_gco2` / `avoidable_io_ops` of the daemon's day, at one significant figure |
| R2 | `POST /api/actions` without an identity is a 403; with `X-Forwarded-User: alice.martin@acme.com` a 201, and the recap carries the action `in_progress` with that owner, `tiles.actions.in_progress` 1 |
| R3 | `PUT /api/labels` and `PUT /api/labels/services` are 403 without an identity and 204 with one; the `pilotage` view titles the row `Showing an order`, names the service `Shop front` on both rows, keeps `endpoint` on the unlabelled row only, and holds none of `signature`, `template`, `suggestion`, `suggested_fix`, `code_location`, `confidence`, `events` |
| R4 | `POST /api/recap/reports` `{"period":"day"}` is a 201 for yesterday with both views and no delivery, the list holds it, and `/recaps/{id}/pilotage.html` and `tech.html` answer 200 `text/html` with a `Content-Security-Policy` and load nothing from elsewhere |
| R5 | the management page shows `Alice Martin` and `An unnamed step in Shop front`, no e-mail anywhere, no `@` outside its `<style>`, no endpoint and no SQL; the tech page keeps `/api/invoices` |
| R6 | the subscription freezes yesterday within one 15-second tick and POSTs it to a loopback receiver; `X-PerfSentinel-Signature` is `sha256=` HMAC-SHA256 of `<X-PerfSentinel-Timestamp>.<body>` under the secret (another secret does not verify), the body is the management view with no technical key, no `endpoint` and no `@`, the two URLs name the frozen pages, the delivery reads `delivered` |
| R7 | the same report reaches a loopback SMTP sink for the subscribed address with one attachment, `perf-sentinel-recap-<day>-pilotage.html`, `text/html`, no `@` outside its `<style>`, the engineering link in the body, the delivery `delivered` |
| R8 | under access control, a report `local:alice` (built-in `member` on `*`) generated reads 200 to her, page included; `local:bob` (`reader` on `*`) reads the recap but gets 404 on her report, on both pages and on the subscription report, with the very body an unknown id gets; bob lists none, alice her own; no session is a 401 |

The management page inlines a stylesheet with `@media` rules, so "no `@`" is
checked outside `<style>`; the e-mail pattern is checked over the whole page.

**What is forged.** A daemon started today holds no sealed yesterday, and a
subscription only freezes a closed period. Before R2 the scenario pushes, with
the source's import key, the ledger page a previous daemon instance would have
pushed for yesterday: a new `ledger_id`, the two planted signatures with 6
detections each, the day sealed, with carbon. Every other value is the daemon's
own. The scheduled path is the real one: the Hub's 15-second loop judges the day
due, freezes it, signs and sends.

## Run

```bash
cd ~/RiderProjects/PerfSentinelHub && dotnet build PerfSentinelHub.sln -c Release
make verify-hub-recap

# Another Hub build or daemon binary:
PERF_SENTINEL_HUB_DLL=/path/to/PerfSentinelHub.dll \
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel make verify-hub-recap
```

The Hub runs as a local `dotnet` process from a Release build, the daemon from
the local perf-sentinel binary. python3 with `opentelemetry-proto`, curl. The
webhook receiver and the SMTP sink are stdlib Python. No cluster, no Docker, no
outbound call (`Hub:UpdateCheck` is off, the OAuth provider is never contacted).
Ports 14970 to 14977 (`HRC_BASE_PORT`). About 45 seconds, more when the daemon's
first ledger push waits for its minute. Within 7 minutes of UTC midnight it
waits for the next day first, since today and yesterday are UTC days.
`KEEP_TMP=yes` keeps the logs. Report at `/tmp/scenario-hub-recap-report.md`.

The scenario SKIPs with exit 0 when the daemon binary, the Hub build, `dotnet`
or `opentelemetry-proto` is absent. A port already answering is a failure.

## What it found (2026-10-29)

PASS on the 0.9.0 release branch (6217142) with the 0.38.0 daemon, 16 checks:
the Hub priced 40 avoidable I/O at 9e-05 g, the daemon's 1.77e-04 g over 80
avoidable I/O. The first run found two scenario faults, no product one: the
cleanup trap stopped at the first `kill` of a dead process, and phase 3 lacked
what access control requires at startup (an admin and `Hub:MetricsPort`). On a
Hub before 0.9.0, `GET /api/recap` is a 404 and the scenario stops at once.
