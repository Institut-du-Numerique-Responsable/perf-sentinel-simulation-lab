# findings-page-filters

The 0.21.0 reading contract of `GET /api/findings`, and the fold behind it.

Self-contained: a local release binary, Docker, `python3` and `curl`. No
cluster, no Prometheus.

## Why it exists

0.21.0 changes four things about how a page of findings is read:

- `?grouping=` filters on the finding's effective grouping, the value the
  `grouping` Prometheus label has carried since 0.19.0, so one Grafana
  variable can drive both shipped dashboards.
- `?offset=` skips folded rows, so a fleet whose distinct signatures outgrow
  the 1000-row cap can be read a page at a time instead of only its newest
  thousand.
- An empty filter value now means no filter, where it was an exact match on
  the empty string. That is what lets a Grafana `All` option, which cannot
  send an empty `allValue` and sends a single space instead, reach an
  exact-match API.
- The fold materialises only the rows a page keeps, instead of cloning the
  first instance of every distinct signature and dropping most of them.

Nothing here covered any of it. The only query forms in the lab were
`service`, `type`, `severity`, `limit`, `since_ms`, `until_ms` and
`include_acked`, and no scenario had ever compared what the fold returns
against a published release. `grouping-identity` pins the grouping *value*
across ingestion boundaries and the JSON, HTML and CSV contracts, and never
reads the API's filters; `grouping-metrics-split` pins the same value on
`/metrics` and never reads the API at all; `query-monitor-api` asserts
`/api/config`, `/api/status` and `/api/energy`, never a findings page.

## What it asserts

| Leg | Claim |
|---|---|
| A | `?grouping=<value>` partitions the listing exactly, and the values it accepts are the ones `label_values(perf_sentinel_findings_total, grouping)` offers, with no conversion. |
| B | An empty, blank or `+` value is no filter, on all four string filters, and a padded value is trimmed. |
| C | `offset` walks the folded listing with no gap and no overlap, past the end is an empty `200`, and a page shortened by the ack screen is not the last page. |
| D | The rewritten fold returns exactly what the latest release returns: same rows, same order, same representative, same counts. |
| E | A `serialized_calls` suggestion names at most three distinct templates, each cut at 120 characters, ends in ` -> ...` when more follows, and keeps the block's real count, total and parallel estimate. |

## Why every leg is an A/B run

Legs A, B, C and E each carry a counter-proof against the before-the-feature
baseline, `ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.20.2`,
and leg D *is* a comparison, against the latest release.

That is not belt and braces. A leg that passes on both builds proves nothing
about the new one, and this lab has shipped that exact mistake: the 0.20.2
ledger entry records a release whose only change no scenario here could see,
which was found by reading the scenarios rather than by running them. The
counter-proofs make the failure mode loud instead. Concretely:

- 0.20.2 ignores an unknown query parameter, so `?grouping=` and `?offset=`
  return the whole listing there. With a single tenant, leg A would read the
  same number on both builds and pass on either; the corpus carries two
  namespaces for that reason alone.
- `?severity=` returns nothing on 0.20.2 and everything on 0.21.0. Leg B
  records that as the behaviour change it is, so a client relying on the old
  exact match is not left to discover it in an issue.
- On the same 40-call fixture the suggestion weighs 153 KB on 0.20.2 and 653
  bytes here. Leg E fails if the baseline sentence is not at least ten times
  the new one, which is what tells "the bound works" from "this fixture never
  produced a long sentence".

Leg D does not compare against 0.20.2. 0.26.2 deliberately changed which
instance represents a tie: a slow-trace finding keeps the smallest trace id,
and every input yields one finding order. From 0.26.2 on, every build differs
from 0.20.2 on a few representatives without losing a row or a count, so
against 0.20.2 the leg fails on a change that is not a fold regression. It
runs a third daemon, on `FOLD_BASELINE_IMAGE`, fed the same corpus, and holds
the fold to the latest release instead. The other four legs keep 0.20.2: they
need a build without the 0.21.0 parameters, and the latest release has them.

Leg D excludes `stored_at_ms` and `first_seen_ms`, which date the reception
and differ between two daemons fed the same corpus at different instants.
Everything the fold itself decides is compared, the representative's
`trace_id` and `severity` included.

It compares **batch by batch**, not row by row. One analysis batch stamps
every finding it produces with a single `stored_at_ms`, and the listing's
documented order is newest first on that stamp; the order of rows *within* one
batch is the order of insertion, which nothing fixes and which moves from run
to run on the same binary. A row-by-row comparison therefore fails on a
reordering the contract never promised, which is exactly what happened on the
first full pass: two adjacent rows sharing a stamp had swapped, on a leg that
had passed in isolation minutes earlier. So the sequence of batches is
compared in order, each side is separately checked to be newest-first, and the
rows inside a batch are compared as a set. Which analysis tick a trace lands
in also depends on when it arrives, so one daemon can split a batch across two
ticks that the other folds as one (a 27-row batch read as 14 + 13 on one run).
Before comparing, consecutive batches are merged on whichever side holds fewer
rows until both sides hold the same rows, and that group is compared as a set;
a group equal in size but not in rows fails at once. A row that moves to a
*different* place in the batch sequence, a changed `seen_count` and a changed
representative are all still caught. `fold_compare.py selftest`, run by
`make validate`, checks both halves on fixtures.

The corpus is `tracegen` at a fixed seed **and a fixed `--run-nonce`**: the
nonce is what the service names derive from, and tracegen picks a fresh one
per process, so two runs of the same seed otherwise differ on every `service`
field and leg D compares nothing but that.

## Running it

```bash
make verify-findings-page-filters
```

Needs a local release build of the product:

```bash
cd ~/RustroverProjects/perf-sentinel && cargo build --release --workspace
```

and `opentelemetry-proto`, which tracegen's `http-pb` protocol imports:

```bash
pip install -r tools/tracegen/requirements.txt
```

Unlike the other local-binary scenarios, this one **fails rather than skips**
when Docker or either baseline image is missing: every leg compares against
one of them, and a scenario that quietly skips them reads exactly like one
that passed.

It also fails, rather than skipping, when the binary under test ignores
`?grouping=`. A release branch keeps the previous version in `Cargo.toml`
until tag time, so `--version` cannot answer whether a build has the
parameter, and the probe asks the daemon instead. From 0.21.0 on, a build
that ignores it is not an old binary, it is a moved contract.

Knobs:

| Variable | Default | Effect |
|---|---|---|
| `BASELINE_IMAGE` | `ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.20.2` | the before-the-feature baseline of the counter-proofs in legs A, B, C and E; fixed, never bumped |
| `FOLD_BASELINE_IMAGE` | `ghcr.io/institut-du-numerique-responsable/perf-sentinel@sha256:81747e45…` (0.34.1) | the latest release, the reference of leg D; bump it with the pin in `manifests/perf-sentinel-daemon.yaml`, same digest |
| `FPF_DAEMON_HTTP_PORT` / `FPF_DAEMON_GRPC_PORT` | `14828` / `14827` | loopback ports of the daemon under test |
| `FPF_BASELINE_HTTP_PORT` | `14838` | published port of the `BASELINE_IMAGE` container |
| `FPF_FOLD_BASELINE_HTTP_PORT` | `14839` | published port of the `FOLD_BASELINE_IMAGE` container |
| `FPF_SEED_A` / `FPF_SEED_B` | `4321` / `9876` | tracegen seeds, one per tenant |
| `FPF_NONCE` | `ab` | tracegen run nonce, shared by both sides so the service names match |
| `FPF_SERIALIZED_CALLS` | `40` | calls in leg E's sequential block |
| `FPF_SERIALIZED_TEMPLATE_BYTES` | `4096` | statement size in that block |

Report: `/tmp/scenario-findings-page-filters-report.md`.

Runtime is about a minute: three daemons, six 6-to-8 second tracegen runs
and two batch `analyze` calls.

When a release ships, bump `FOLD_BASELINE_IMAGE` in `verify.sh` to the digest
`manifests/perf-sentinel-daemon.yaml` pins, in the same change, with the
version in the trailing comment. Leg D then holds the fold to what that
release returns. A leg D failure right after a release that changed
representatives on purpose means the pin is stale, not that the fold broke:
check the release notes before reading it as a regression.

## Files

- `verify.sh` — the five legs.
- `serialized_fixture.py` — leg E's corpus. tracegen has no `serialized`
  pattern and its templates are short, so neither knob reaches the sentence
  the leg measures: one root span and N SQL children, each starting after the
  previous one ends, each statement padded past the 120-character cut.
- `fold_compare.py` — reads a page dump: row counts, signatures, row keys,
  grouping values, one finding's suggestion, and the leg D comparison.
