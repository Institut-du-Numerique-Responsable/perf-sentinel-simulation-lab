# hub-disclosures

**Claim.** A CI publishes a periodic disclosure to PerfSentinelHub 0.7.0 or later, whose
embedded perf-sentinel 0.31.0 or later checks and renders it before anything is kept. The Hub
shares it through an expiring link that `verify-hash --url` reaches over https, refuses edited
figures and an internal report, and signs a webhook at publication and at withdrawal.

## Setup

One isolated Hub in the scenario's own namespace, from the image the shared Hub runs (seed it
with `make seed-hub-local`; before engine 0.31.0 is published, set `HUB_ENGINE_IMAGE` to a
`make seed-daemon-local` tag so the Hub embeds an engine with `disclose-pdf`):

- disclosures on, with a scenario-generated import key, and one webhook to a receiver running
  beside the Hub in its pod, since a webhook may be plain http to loopback only;
- the Hub trusts the identity header, so the scenario names itself on the manage routes;
- a local TLS relay, signed by a throwaway CA, in front of the port-forward: `verify-hash --url`
  fetches https only.

The local engine (`PERF_SENTINEL_LOCAL_BIN`) runs `disclose`, `hash-bake` and `verify-hash`.

## Legs

1. `disclose --emit-attestation` over the `disclose` fixtures, published: 201, PDF rendered,
   content hash and binding checked here.
2. A share link: `verify-hash --url` on it and `verify-hash --report` on the PDF it serves are
   both PARTIAL with the content hash and the binding OK.
3. One figure halved under a new uuid: 422 `content_hash_mismatch`, then with the hash re-baked
   422 `binding_mismatch`. One disclosure stored.
4. An internal report: 422 `internal_refused`.
5. The receiver got `published` with a valid HMAC. A withdrawal answers 204, the link answers 404
   at once, and `withdrawn` arrives with a valid HMAC.

## Not proven here

TRUSTED: the lab has no Sigstore identity. The engine's `disclosure-signing.yml` workflow proves
it with a real keyless signature on a PDF.
