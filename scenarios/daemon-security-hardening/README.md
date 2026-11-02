# daemon-security-hardening

Three 0.41.0 hardening gates of the daemon's HTTP listener, checked against a
throwaway container of the image under test.

## Why it exists

perf-sentinel 0.41.0 hardens the daemon's listener. Three of the changes have a
visible contract on the wire:

- OTLP exports are counted before decoding. A request with more than 100,000
  spans, or more nested elements than `max(max_payload_size / 4, 100,000)`,
  gets 413 over HTTP and is counted in
  `perf_sentinel_otlp_rejected_total{reason="too_many_spans"}`. An empty span
  costs two bytes on the wire, so before 0.41.0 a 200 KB request expanded to
  100,001 decoded structs.
- `[daemon] allowed_hosts` lists the names the listener answers. A Host outside
  the list, `localhost` and IP literals gets 421. On a loopback bind the check
  always applies. On another bind it applies once the list is set.
- `GET /api/findings?include_acked=true` exposes the ack audit trail (reviewer,
  reason, expiry), so it now needs the ack key or `read_api_key` when an ack key
  is set, like `GET /api/acks`.

## What it asserts

| id | assertion |
|----|-----------|
| O1 | an OTLP HTTP export of 100,001 empty spans answers 413 |
| O2 | `perf_sentinel_otlp_rejected_total{reason="too_many_spans"}` grows by exactly 1 |
| O3 | the same export with 10 empty spans answers 200 (control) |
| H1 | with `allowed_hosts = ["perf-sentinel.lab.internal"]`, `Host: evil.example` answers 421 |
| H2 | `Host: perf-sentinel.lab.internal:<port>` answers 200, and so do `localhost` and the IP literal `127.0.0.1` |
| A1 | with `[daemon.ack] api_key` set, `GET /api/findings?include_acked=true` without a key answers 401 |
| A2 | the same request with `X-API-Key: <ack key>` answers 200 |
| A3 | `GET /api/findings` without `include_acked` stays open (200) |

The daemon listens on `0.0.0.0` inside the container so the published loopback
port reaches it, which makes it a non-loopback bind: the Host check applies
because the list is set. The loopback default (check on, no list) is covered by
the engine's own tests and not repeated here.

Against 0.40.0 the daemon refuses the configuration at start-up (`unknown
field allowed_hosts`), so the scenario stops before its first assertion,
observed on 2026-11-02.

## Prerequisites

- Docker, `curl`, `python3`.
- Port 15440 free on loopback (`PORT` overrides it).
- The image resolves through `scripts/resolve-image.sh`.

## Run

```bash
make verify-daemon-security-hardening
# or
./scenarios/daemon-security-hardening/verify.sh
```

A few seconds. Report: `/tmp/scenario-daemon-security-hardening-report.md`.
