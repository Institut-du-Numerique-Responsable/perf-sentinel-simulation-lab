# card-cli

The 0.39.0 share-card commands, `card keygen`, `card render` and
`verify-card`, against the contract of the engine's `docs/SHARE-CARD.md`.

## Why it exists

A share card prints what Perf Sentinel measured about a waste pattern, signed
with an Ed25519 key, so anyone can check the figures and, at level 2, that the
signer's domain publishes the key. PerfSentinelHub writes a `card.json` and
calls the binary to draw and sign it, then readers run `verify-card` or the
verify page. Each command prints one JSON line with a closed list of reasons
and documented exit codes (C2), and `card.json` follows contract C3. This
scenario holds the binary to those lines and codes, offline and with
`--online`.

## What it asserts

The inputs are the engine's own fixtures, `tests/fixtures/card/story.json`,
`curve.json` and `collective.json` (`CC_FIXTURES` to point elsewhere).

| id | assertion |
|----|-----------|
| K1 | `card keygen --out-dir` prints `{fingerprint, public_key}`, the fingerprint is `ps1:` and 22 base64url characters, equal to the base64url of the first 16 bytes of the SHA-256 of the 32-byte public key, and `<fingerprint>.pk8` is mode 0600 |
| K2 | `card render` of the 3 fixtures in `png`, `pdf`, `svg` and `jxl`: exit 0, `{"result":"rendered","files":["card.<f>"],"fingerprint":<K1>}` with a `https://perf-sentinel.dev/verifier#c=` URL, and that file alone in the directory |
| K3 | rendering the story again gives the same bytes in all four formats |
| K4 | `verify-card` offline on the 12 originals: exit 0, `integrity` ok, `content` intact, level 1, key unknown, `no_key_list`, the card's domain, and `figures` equal to the input's (story `before_fix_ops` and `cited_ops`, curve `last_waste_permille` and `previous_waste_permille`, collective `confirmed_fixes_count` and `services_count`, plus angle, period and before-fix period) |
| K5 | `--keys` with a local list naming the key from 2026-09-01: level 2, current, `key_published` |
| K6 | the story PNG with one byte flipped inside `IDAT`, its CRC recomputed: exit 1 and exactly `{"integrity":"ok","content":"modified","level":1,"domain":null,"key":"unknown","reason":"content_modified","figures":null}` |
| K7 | a story whose period starts on 2026-09-02: `{"result":"refused","reason":"period_not_calendar"}`, exit 1; a float `cited_ops`: `{"result":"input_error","reason":"malformed_input"}`, exit 3; neither writes a file |
| K8 | `verify-card --online --doh` on a story signed for `card-lab.test`: the TXT record alone (well-known 404) and both sources give level 2, `key_published`; a record with `revoked=` gives level 1, `revoked`, `key_revoked`, exit 1; a DoH 500 gives `binding_check_failed` when the well-known file is 404 and `binding_partial` when it lists the key, both level 1, exit 4; the K6 file makes no request at all |

### How `--online` runs locally

`--online` reads `_perf-sentinel.<domain>` TXT through a DoH JSON service
(`--doh` takes an `https://` URL) and
`https://<domain>/.well-known/perf-sentinel-key` on the domain itself, no
port. The domain must pass the card's domain rule (two labels or more, the
last not all digits), so `localhost` or `127.0.0.1` cannot stand in. The
scenario mints a throwaway CA with a certificate for `card-lab.test` and
`doh.card-lab.test`, serves both answers from one python TLS origin, and
points the binary at a python CONNECT proxy through `HTTPS_PROXY`, with the
CA in `SSL_CERT_FILE` (both read by the engine's HTTP client since 0.25.5).
The proxy sends every tunnel to the origin, so the host never resolves the
names. The origin answers `application/dns-json` with the question and a
quoted TXT answer, `Status 3` (NXDOMAIN) when no record is set. K8a also
checks the binary asked `name=_perf-sentinel.card-lab.test&type=TXT` with
`Accept: application/dns-json`.

## Run

```bash
cd ~/RustroverProjects/perf-sentinel && cargo build --release -p perf-sentinel
make verify-card-cli

# Another binary:
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel make verify-card-cli
```

Local release binary, python3, openssl, cmp. No cluster, no Docker, a few
seconds. Ports 14956 (TLS origin) and 14957 (proxy), `CC_ORIGIN_PORT` and
`CC_PROXY_PORT`. Every leg runs with the operator's proxy and trust variables
unset. Report at `/tmp/scenario-card-cli-report.md`.

## Watch out

- `card keygen --out-dir` does not create the directory: a missing one gives
  `{"result":"input_error","reason":"output_unwritable"}`, exit 3. The docs
  do not say it creates it, so the scenario creates it first.

## What it found (2026-10-30)

On 0.38.0, K1 FAIL by construction: there is no `card` subcommand. No 0.38.0
binary was run. On 0.39.0, PASS in a few seconds: 12 cards (about 1.6 MiB in
all), byte for byte reproducible, all intact offline with the input's
figures. The retouched PNG prints the documented `content_modified` line word
for word. Through the fake DoH and well-known origin, the five `--online`
cases give the documented level, reason and exit, and the retouched file
sends no request. No disagreement with the docs.
