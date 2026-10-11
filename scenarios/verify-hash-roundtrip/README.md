# verify-hash-roundtrip

CLI contract regression scenario for `perf-sentinel verify-hash`, locking the
v0.7.0 breaking change (identity flags required by default, exit codes
redesigned to 0/1/2/3/4).

## What it covers

7 sub-tests run inside `ghcr.io/institut-du-numerique-responsable/perf-sentinel:${PERF_SENTINEL_VERSION}`
(defaults to the lab's currently-pinned version):

1. **Placeholder hash detection** (exit 1, UNTRUSTED).
   The upstream `docs/schemas/examples/example-official-public-G2.json`
   ships with a zeroed `integrity.content_hash` placeholder. Running
   `verify-hash --report` against it must recompute, mismatch, and exit 1
   with `[FAIL] Content hash` on stdout.

2. **Missing report INPUT_ERROR** (exit 3).
   Distinct exit code from a tamper (exit 1) so wrapper scripts can
   react differently to a wrong path than to a forged report.

3. **HTTP URL NETWORK_ERROR** (exit 4).
   HTTPS-only hardening. `--url http://...` must be rejected before any
   network call. Distinct exit code from INPUT_ERROR (exit 3).

4. **Identity-required default** (exit 1, breaking-change error string).
   With `integrity.signature` populated and no `--expected-identity` /
   `--expected-issuer` / `--no-identity-check` passed, verify-hash must
   refuse with the grep-stable string `cannot verify without expected
   identity`. This is the v0.7.0 breaking change: a Sigstore bundle
   without an identity constraint can be forged by any GitHub or Google
   account holder, so the CLI now requires the operator to opt out
   explicitly with `--no-identity-check`.

5. **Half-pair rejection** (exit 1).
   Passing only one of the `--expected-identity` / `--expected-issuer`
   pair must fail with the grep-stable string `both --expected-identity
   and --expected-issuer must be passed together`. Prevents accidental
   single-flag use that would silently downgrade verification.

6. **hash-bake roundtrip on unsigned report** (verify-hash exit 2
   PARTIAL, v0.7.2 `hash-bake`). Bakes the canonical `content_hash`
   into the G2 fixture, then runs `verify-hash` against the baked file.
   With the signature still null in the fixture, the run returns
   `[OK] Content hash` (the bake produced the canonical value) and
   `PARTIAL` overall (signature NotProvided). Locks that hash-bake
   produces what verify-hash recomputes, and the exit 2 PARTIAL path.

7. **hash-bake refuses signed report by default** (exit 1, accepts with
   `--allow-signed`). Re-runs hash-bake on the synthetic-signature
   variant from sub-test 4. Asserts the safety default: hash-bake
   refuses to rewrite a report whose `integrity.signature` is already
   populated, and only accepts the rewrite when `--allow-signed` is
   passed explicitly. Locks the v0.7.2 guard against accidental
   signature-invalidation.

## Coverage gaps tracked

- **exit 0 (TRUSTED) end-to-end roundtrip**: still uncovered, requires
  a real cosign-signed bundle paired with `cosign verify-blob`
  succeeding and a matching `--expected-identity`/`--expected-issuer`.
  Out of scope without an OIDC ceremony in the lab. Future unlock
  candidate: a sigstore mock returning a deterministic valid bundle,
  or a committed pre-signed fixture maintained as the canonical
  signing identity rotates.

- **exit 2 (PARTIAL) on hash-valid + signature-absent**: covered by
  sub-test 6 since v0.7.2 (closed).

## Runtime

CLI-only, ~10 seconds. No cluster contact, no daemon dependency.

Dependencies: `docker`, `jq`.

## Reproducibility

```
PERF_SENTINEL_VERSION=0.7.1 ./scenarios/verify-hash-roundtrip/verify.sh
```

The fixture under `fixtures/example-official-public-G2.json` is a
verbatim copy of the upstream example at
`docs/schemas/examples/example-official-public-G2.json`. If the upstream
example evolves, refresh the fixture with:

```
cp "${PERF_SENTINEL_REPO_PATH}/docs/schemas/examples/example-official-public-G2.json" \
   scenarios/verify-hash-roundtrip/fixtures/example-official-public-G2.json
```

## Which binary this runs against

`scripts/resolve-image.sh` picks the image: `PERF_SENTINEL_IMAGE` (a full
reference, for a locally built pre-release), then `PERF_SENTINEL_VERSION` (a
GHCR tag), then the pin in `manifests/perf-sentinel-daemon.yaml`.

It used to default to a hardcoded old tag, so the scenario ran
green on every release without ever touching the version under
validation. The gate reported a PASS for code it had not executed.
The 0.9.25 round is what surfaced that, and every image-based
scenario now shares this resolution.
