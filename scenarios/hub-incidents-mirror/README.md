# hub-incidents-mirror

The daemon-to-Hub incident chain, end to end, over the shared lab pair, with
one leg on an isolated pair of its own.

## Why it exists

perf-sentinel 0.20.0 freezes the findings of the window that preceded an alert.
PerfSentinelHub 0.1.6 mirrors those records into SQLite and serves them back.
Neither repository tests the join. The Hub's own tests drive a fake daemon that
answers a hand-written page. The daemon's tests never see a Hub.

Two lab scenarios cover a half each and neither covers the seam.
[`incident-window-capture`](../incident-window-capture) proves the capture
against a local binary with no cluster and no Hub: the freeze at reception, the
settle merge, idempotent reposts, counted refusals, the NDJSON archive.
[`hub-ingestion`](../hub-ingestion) proves the findings path over the cluster
and stops there, because incidents did not exist when it was written.

What was left uncovered is the reason the feature exists. A pod that gets
OOM-killed takes its findings ring with it, and the record that would explain
the outage is destroyed by the outage. The Hub's copy is the only thing left to
read. A field renamed on either side, or an upsert that let a re-capture
overwrite a full one, would ship green in both repositories.

## What it asserts

1. **The daemon freezes the window an alert names.** One Alertmanager envelope
   posted with the incidents WRITE key is recorded, and the record read back
   with the READ key carries the service, the window at
   `[at - lookback_ms, at + 2 x trace_ttl_ms]`, at least one frozen finding and
   the namespace the alert labelled.
2. **The Hub holds a copy, not a re-derivation.** `POST /api/incidents/refresh`
   reads the fleet on demand. The listing carries the record keyed per source,
   with `source_id`, `environment`, `finding_count` and a `capture` verdict
   derived from the daemon's own `oldest_finding_ms`, and WITHOUT the findings,
   which the listing query never reads. `GET /api/incidents/{id}` then returns
   them whole, signature for signature against what the daemon froze.
3. **Every filter narrows, and the closed ones refuse.** `service`, `namespace`,
   `kind` and `source_id` each narrow to rows that all match. A service nobody
   reports is an empty page. An unknown `kind`, `environment` or `source_id`
   answers 400, because an empty incidents screen is the answer an operator
   hopes for and a typo must not be able to produce it.
4. **A refused read key stays in its lane.** With the wrong key on the Hub's
   source entry, `incidents_state` reads `unauthorized` while the source stays
   reachable, keeps a null `unreachable_since_ms` and goes on reporting its
   findings. This is the invariant the reader was built around: an incidents
   read files its own outcome and never touches `source_state`.
5. **The shared daemon replays its archive.** Since perf-sentinel 0.24.0 the
   daemon reloads its incident ring from `[daemon.incidents] archive_path` at
   startup, and the lab keeps that file on the `perf-sentinel-acks` PVC. After
   a restart the shared daemon lists the incident again with the signatures it
   froze.
6. **The copy outlives the ring, and a poorer capture never replaces it.** On
   an isolated daemon and Hub with no `archive_path`, restarting the daemon
   empties its ring, and the Hub still serves the record with its findings.
   Reposting the same envelope makes the restarted daemon capture the same id
   against a ring that no longer reaches the window, and the Hub keeps the
   richer document. Both verdicts also require the source's `incidents_state`
   to be `ok` with an `incidents_read_ms` past the restart or the repost, and
   the record's `last_seen` past the repost, since a refresh answers 200 even
   when its read failed.

## The two keys

The daemon gates `POST /api/incidents` on `[daemon.incidents] api_key` and
opens the GETs to `[daemon] read_api_key` as well. The lab wires them as two
distinct values in the `perf-sentinel-api-keys` Secret, and the Hub is given
the READ one: nothing whose job is to read should be able to post an incident.
The scenario uses both, the write key to post and the read key to read back,
which is also what proves the two are actually distinct in the cluster.

## Mutating the shared pair

Leg 4 needs the Hub to hold a key the daemon refuses. The Hub reads its source
list once at startup, so the wrong key has to arrive through a rollout. The
narrowest way is a strategic merge patch on one env var of the Hub Deployment,
replacing the `secretKeyRef` with a literal and putting the reference back
afterwards. The shared Secret is never touched, so the daemon and every other
scenario see nothing, and the restore runs from the cleanup trap whatever
happens in between.

Leg 5 restarts the shared daemon, which several scenarios already do
([`cold-start-edge-cases`](../cold-start-edge-cases),
[`failure-mode-daemon-restart`](../failure-mode-daemon-restart)). It leaves the
findings ring empty behind it, the same state a plain `make up` starts from.
The incident ring comes back from the archive, which is why that restart can
no longer prove the Hub's copy outlives it.

## The isolated pair

Leg 6 needs a daemon that really loses its incidents on a restart. It copies
the shared daemon and Hub images into a pair of its own in the
`hub-incidents-mirror` namespace, in the shape of
[`hub-source-reachability`](../hub-source-reachability): `[daemon.incidents]`
enabled with no `archive_path`, a 5-second `trace_ttl_ms` so the settle pass is
short, the lab's two keys copied into a local Secret, and a tracegen Job aimed
at that daemon. The trap deletes the namespace on every exit path; set
`KEEP_NAMESPACE=yes` to keep it for debugging.

## What it does not assert

- **The capture semantics themselves.** The settle merge, repost idempotence,
  the counted refusal reasons, the `endsAt` rules and the NDJSON archive are
  [`incident-window-capture`](../incident-window-capture)'s subject, against a
  local binary where a symlinked archive path and a 1001-alert delivery are
  cheap. Here the daemon is a black box that answers two routes.
- **A second daemon.** One incident id held by two sources, the per-source copy
  it implies, and the single-incident route's tie-break on the richest capture
  are untested. The richest-copy rule is proven within one source only, by
  making the isolated daemon re-capture the same id after losing its ring.
- **That the `source_id` filter narrows anything.** The lab configures one
  source, so the filter can only ever return everything. Its refusal of an
  unknown id is what this scenario proves, not its selectivity.
- **The poll path on its own interval.** The scenario forces every read with
  `POST /api/incidents/refresh` rather than waiting out `PollInterval`. The
  incidents read the poll worker performs inside a normal poll is exercised in
  passing during leg 4, never asserted.
- **The reader's paging.** The 100-incident page size, the halving retry on a
  page over the 4 MiB body cap and the 1000-incident ceiling need a daemon
  holding far more incidents than this scenario creates.
- **Retention.** How long the Hub keeps an incident is
  [`hub-retention-purge`](../hub-retention-purge)'s subject.
- **What reads the record.** The IDE plugin's parse of an incident is not
  covered here, in the way [`hub-plugin-contract`](../hub-plugin-contract)
  covers the finding envelope.
- **Alertmanager.** The envelope is hand-built to the shape the daemon accepts.
  That a real Alertmanager receiver posts exactly this is a deployment
  question, and the intake's refusal counters are the only signal when it does
  not, which `incident-window-capture` covers.
- **The archive's own rules.** Leg 5 proves only that a restart brings the
  record back. The last-record-wins replay and the tail-only read of a large
  file are the daemon's own tests' subject, the guards on the path are
  [`incident-window-capture`](../incident-window-capture)'s.

## Running it

```bash
make verify-hub-incidents-mirror
```

Needs the cluster, `make seed-hub-local`, `make seed-tracegen` and
`make port-forward`. The two API keys come from `scripts/bootstrap.sh`, which
`make up` runs.
