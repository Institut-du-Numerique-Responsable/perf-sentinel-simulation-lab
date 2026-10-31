# hub-card

PerfSentinelHub 0.10.0 turns a closed period's confirmed fixes into a share card
the engine draws and signs (`perf-sentinel card render`), in PNG, SVG, JPEG XL or
a PDF carousel, which anyone checks with `perf-sentinel verify-card`. The same
release asks each pushing daemon to watch the threshold findings marked fixed
(`watch` in the push answer), the signal a threshold card stands on.

## Why it exists

`card-signal` proves the 0.39.0 daemon against a fake Hub, `card-cli` the
engine's card commands on fixtures, and the Hub's tests prove its routes with a
fake clock and a seeded store. None of them sees the others. This scenario is
the seam: a real 0.39.0 daemon pushes to a real Hub process, which hands it the
watch list, makes its signing key and its cards with the real engine, and the
files it serves pass `verify-card` offline.

## What it asserts

A local Hub knows two sources. `hcd-lab` is fed by a local daemon
(`slow_query_threshold_ms = 250`) through a loopback proxy that records every
answer to the detection push. `hcd-week` (`week daemon`) stands for the daemon
that watched the same service over the two closed ISO weeks before this one; its
address is a second, idle 0.39.0 daemon, so the Hub's poll reaches it (a fix only
confirms on the sealed days of a reachable source). The pushing daemon receives 8 N+1 traces on `/api/orders` and one slow SELECT on
`/api/report`, service `hcd-shop`. The Hub restarts on one database: phase 0
with cards off, phases 1 and 2 with `Hub:Cards:Organisation`, `Hub:Cards:Domain
= card-lab.example`, `Hub:Cards:MaxConcurrentRenders = 1` and the proxy identity
header trusted, phase 3 with access control, two local accounts, no domain and
`Hub:DetectionRetention = 200.00:00:00`.

| id | assertion |
|----|-----------|
| H0 | cards off: the six card routes answer 404 and `/api/status` carries no `cards`; on, it reads `cards: true` and the engine's version |
| H1 | both findings reach the Hub; `POST /api/actions` with `status: done` stores `frozen_finding_json` holding the signature for each (schema V20); a `PATCH` back to `in_progress` clears it with `done_at_ms` |
| H2 | after a daemon restart, the first accepted push answer of the new ledger is `watch: [<slow_sql>]`, the N+1 left out; `hcd-week`, which never detected the slow SELECT, gets `watch: []`. Four traces at 100 and at exactly 250 ms give the daemon's row `detections: 0`, `below_threshold_passes: 8`; a push carries it, the Hub stores `(0, 8)` for that ledger and its windowed `GET /api/findings` still counts the first ledger's single detection |
| H3 | `GET /api/cards/options?period=week` on the closed week: no refusal, signed scope `[week daemon]` (`hcd-lab`, whose ledgers start today, left out), `restart_days` 0, `previous_whole`, one confirmed fix, the N+1, default, with 175 I/O before and its done date; `GET /api/recap?period=week` on that week names `late_sources: ["lab daemon"]`, `hcd-lab` by its name |
| H4 | `GET /api/cards/keys` before any card lists no key; a story card in `png`, `svg`, `jxl` and `pdf` answers 200 with its type, `filename=perf-sentinel-card-week-<monday>.<format>`, `no-store` and `nosniff`, the SVG with `default-src 'none'; sandbox`; each file passes `verify-card` offline: exit 0, `integrity` ok, `content` intact, level 1, domain `card-lab.example`, story over the week, before-fix period the week before, `cited_ops` the frozen finding's occurrences and `before_fix_ops` 175 |
| H5 | the first card made one key, current from today, `record_name` `_perf-sentinel.card-lab.example`, DNS `v=ps1; k=<fp>; from=<today>`, and card 1 reads level 2 `current` against its `well_known`; a rotation retires it (`to` today, a new DNS line) for a new current key, and against the new `well_known` card 1 (old key) and card 2 (new key) both read level 2; revoking the old key from today puts `revoked=` in its DNS line, card 1 then exits 1 `key_revoked` and card 2 stays level 2; an unknown fingerprint is a 404 |
| H6 | four parallel PDF renders past `MaxConcurrentRenders = 1` give a 200 and a 503 `Another card is being made. Try again in a few seconds.` with `Retry-After: 5` |
| H7 | a sealed day 300 days old, past the 180-day `Hub:Retention`, outlives the boot purge under the default 1,100-day `Hub:DetectionRetention`; with 200 days it is purged at boot and the weeks before stay |
| H8 | under access control, bob (`reader`, no `cards.write`) has no `cards` in `/api/status` and gets 403 `You may not create cards.` on options and render; alice (`member`) reads `cards: true` and the options with the fix, gets 403 `You may not manage the card signing key.` on the keys and 409 `Set Hub:Cards:Domain to check an attachment.` on `POST /api/cards/attachment` |

**What is forged, and why.** A card covers a closed period and a fix marked
done inside it, so a run on one day needs history. The lightest honest way:

- `hcd-week`'s ledger, imported with its own key through
  `POST /api/import/detections`, the route its daemon would have pushed to: the
  two weeks sealed, the planted N+1 six times a day with 25 extra I/O until the
  day before the fix, then clean sealed days, with carbon on each day. Plus one
  sealed day 300 days old in a second ledger, for H7.
- The done date of the N+1 action. The action is created by the route, which
  freezes the daemon's own finding; then, with the Hub stopped, one SQL UPDATE
  moves `created_at_ms`, `updated_at_ms`, `done_at_ms` and the event's `at_ms`
  to the Thursday of that week at 10:00 UTC. No route sets a done date in the
  past. The Hub's tests do the same with a fake clock
  (`PerfSentinelHub.Tests/Support/CardSeed.cs`).

The fix is confirmed at `hcd-week` only: `hcd-lab` detected the N+1 today, after
the fix, but its ledgers start today, so the card leaves it out of the signed
scope and judges the fix on `hcd-week`'s days. Everything else, the finding, its
frozen envelope, the watch list, the passes, the cards and the keys, is the
daemon's, the Hub's and the engine's own.

**No network.** `POST /api/cards/attachment` is called only without
`Hub:Cards:Domain`, its 409, so the engine's `--online` check, which reaches
`cloudflare-dns.com` and the domain, never runs. `card-lab.example` is a
reserved name. `Hub:UpdateCheck` is off, the OAuth provider is never contacted.

## Run

```bash
cd ~/RiderProjects/PerfSentinelHub && dotnet build PerfSentinelHub.sln -c Release
make verify-hub-card

# Another Hub build or engine binary:
PERF_SENTINEL_HUB_DLL=/path/to/PerfSentinelHub.dll \
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel make verify-hub-card
```

The Hub runs as a local `dotnet` process from a Release build, the daemon and
the card engine from the local perf-sentinel binary (`Hub:Analysis:EngineBinaryPath`).
python3 with `opentelemetry-proto`, curl. No cluster, no Docker. Ports 14980 to
14988 (`HCD_BASE_PORT`). About three minutes, most of it the daemon's detection
push, at most once a minute. Within 10 minutes of UTC midnight it waits for the
next day first. `KEEP_TMP=yes` keeps the logs, the database and the cards.
Report at `/tmp/scenario-hub-card-report.md`.

The scenario SKIPs with exit 0 when the daemon binary, the Hub build, `dotnet` or
`opentelemetry-proto` is absent. A port already answering is a failure, and so
is an engine without `card`.

## What it found (2026-10-31)

PASS on the 0.10.0 branch (`feat/card`, 6e27e22) with the 0.39.0 daemon and
engine, 23 checks, under four minutes. The card names the N+1 fix done on
2026-10-22 with 6 cited calls and 175 I/O over 2026-10-12..2026-10-18, and the
four files read intact at level 1. The DNS line grows `; to=<day>` at rotation
and `; revoked=<day>` at revocation; a rotated-out key keeps vouching for its
card (level 2), a revoked one turns it into `key_revoked`, exit 1. Four parallel
renders gave one 200 and three 503.

The first runs found three scenario faults, no product one. `hcd-week` behind a
closed port read as unreachable, and an unreachable source never confirms a fix
(docs/API.md, recap actions): the options came back with no refusal and no fix,
hence the idle daemon at its address. `late_sources` carries source names, not
ids. And bash 3.2 cannot parse a `case` inside `$(...)`.

Worth knowing: any card needs its fix's source reachable by poll (confirmation),
and a threshold story also needs it pushing (the `watch` list only travels in
the push answer). The share card section of docs/LIMITATIONS.md states the
second; the first is only in docs/API.md, under the recap's actions, so a
push-only daemon behind a closed address gets no fix in the options and a
`no_confirmed_fix` on render.
