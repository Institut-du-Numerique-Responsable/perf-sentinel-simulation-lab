# hub-access-control

Hub access control on the NativeAOT image: who reaches what, with every
credential the Hub accepts.

## Why it exists

The Hub's tests drive access control through TestServer, with a fake daemon and
no real Kestrel. Some things only show on the shipped image: the OAuth and
cookie handlers under NativeAOT, the bearer scheme over real Kestrel, the
metrics port that stops the Hub when it is not bound, the daemon's read gate as
a polling Hub sees it, and the token file the real CLI writes for the JetBrains
plugin to read. Each leg crosses one of those boundaries.

## Setup

An isolated pair, daemon and Hub, in the `hub-access-control` namespace, for the
same reason as `hub-source-reachability`: the zero-trust policy admits a polling
Hub only from its own namespace. Both image pins are copied from the shared
deployments, which stay access-off and untouched.

- **Daemon:** `require_read_key = true` (the key from a Secret), acks off,
  `grouping_attributes = ["k8s.namespace.name"]`.
- **Traffic:** one tracegen Job in the namespace, four runs with one nonce.
  `aca-a` under the tenant `aca-a`, `aca-b` under `aca-b`, and `aca-shared` under
  both with the same seed, so its signatures coincide across the two tenants.
- **Hub:** polls every 5 s, the daemon twice: `keyed` with the read key,
  `keyless` without. Auth against a fake provider, `RequiredGroups:
  ["/lab/users"]`, `TrustedProxyNetworks: ["127.0.0.1/32"]` (non-empty is what
  maps the device routes and admits local accounts). Access with one project `a`
  on `k8s.namespace.name=aca-a` and none for `aca-b`; the built-in `reader` on
  `a` for `internal:devs` (holding `local:ops`), `internal:ci-a` and the provider
  group `/teams/a`; `local:ops` in `Admins`; machine tokens `tok-a`, `tok-none`
  (a group with no grant) and `tok-expired`; `MetricsPort: 9464` with
  `ASPNETCORE_HTTP_PORTS="8080;9464"`. Every secret is generated per run and
  reaches the pod through env from a Secret, under the names the chart uses.
- **Fake provider:** about forty lines of stdlib Python in a sidecar of the Hub
  pod, on `127.0.0.1:9400`, which the validator allows over `http`. The code is
  the user's name and the access token is the code. curl plays the browser and
  skips the provider's page: it calls `/auth/callback` with the state and the
  correlation cookie from the Hub's challenge.
- **Port-forward:** `8096 -> 8080` and `8097 -> 9464`.

`hub_session` and the correlation cookie are `Secure`, and curl's cookie jar
never sends a `Secure` cookie over `http`, so every cookie travels as an explicit
`Cookie:` header.

## What it asserts

1. **E, local account.** `GET /` without a session is a `302` to
   `/auth/sign-in?return_url=…`, `/api/findings` a `401`. The sign-in page's CSP
   allows its style by `sha256` hash, as the code sends it. A wrong password gets
   `403` "The name or the password is wrong.", the right one `302` and
   `hub_session`. The admin's `/api/access`: `session`, `local:ops`, admin,
   `local_accounts` `["ops"]`, the `aca-b` attribute in `unmatched`, and an
   `aca-shared` copy with values `[aca-a, aca-b]` in `conflicts`.
2. **A, the daemon gate.** `keyed` is reachable; `keyless` is not, with
   `last_error_code` `http_error`. Every finding's `sources[]` names `keyed` only.
3. **B, grouping.** `grouping=aca-a` lists `aca-a` and `aca-shared`, `aca-b` the
   mirror, `aca-zzz` nothing; `grouping=`, `%20` and `+` equal the unfiltered
   listing.
4. **C, machine tokens.** `tok-expired`: `401` with
   `WWW-Authenticate: Bearer error="invalid_token"`. `tok-none`: `403` "No grant
   gives you findings.read on this Hub.". `tok-a` with the plugin's query
   (`service`, `limit=1000`, `include_acked=true`): rows for an `aca-a` service,
   `[]` for an `aca-b` one; unfiltered, `aca-a` and `aca-shared`, never `aca-b`.
   An ack is `403` "A machine token only reads.". Responses carry
   `Content-Security-Policy: frame-ancestors 'self'`. `/api/access`:
   `machine_token`, not admin, `findings.read` alone on every reach.
5. **D, the metrics port.** `/metrics` is `404` on the main port and `200` on the
   metrics port, where `/health/ready` is `404`. D2: the image with
   `Hub__MetricsPort=9464` and only 8080 bound exits 1 with event `2002`.
6. **F, terminal sign-in.** `perf-sentinel login` prints a code; the admin
   session verifies it (`same_network` true) and approves it (`204`); login exits
   0. `hub-token.json` is `0600` in a `0700` directory, with exactly `hub_url`
   (the `--hub` string), `token` (`pshub_…`) and `expires_at_ms`, the keys the
   plugin reads. `hub findings` lists `aca-a` and no `aca-b`; `/api/access` says
   `terminal_token`, not admin. `logout` prints "Signed out of", deletes the file,
   and the old token gets `401`. With `PERF_SENTINEL_HUB_TOKEN=<tok-a>`,
   `hub findings` exits 0 and `hub ack` exits 1 on "A machine token only reads.".
7. **G, provider sign-in.** The SSO challenge redirects to the provider with a
   state and sets a correlation cookie. `alice` gets a session: subject
   `u-alice`, identity `alice@lab`, groups `/teams/a` alone (`/lab/unlisted` is
   dropped), no `aca-b` finding. `bob` (not in `/lab/users`) and `mallory` (sub
   `local:ops`) get `403` "Sign-in refused. …", and event `1900` gives each reason.

## Settled on the first run

- The keyless source's `last_error_code` is `http_error`: the Hub maps any HTTP
  status from a daemon to it.
- The OAuth callback is accepted over plain `http` with the correlation cookie
  sent explicitly; no `X-Forwarded-Proto` is needed.
- The port-forward reaches the Hub from `127.0.0.1`, inside
  `TrustedProxyNetworks`.

## Not covered

A real IdP (Keycloak and GitLab claim shapes), the Helm chart's wiring, the
404-versus-400 scope rules, throttling, the token cap and `/api/tokens`, startup
refusals, analyses with access on, the live report's key prompt and the plugin's
IDE UI. The Hub's own tests own those.

## Running it

```bash
make verify-hub-access-control
```

Needs the cluster, `make seed-daemon-local`, `make seed-hub-local` (the Hub image
must also be in local docker: `hash-password` and leg D2 run it),
`make seed-tracegen`, and a local `perf-sentinel` with `login` (`cargo build
--release`; `PERF_SENTINEL_REPO_PATH` or `PERF_SENTINEL_LOCAL_BIN` point at it).
Ports 8096 and 8097 must be free. About two minutes. `KEEP_NAMESPACE=yes` keeps
the namespace and `/tmp/hub-access-control/` (mode 0700, it holds live session
cookies) for inspection; the next run deletes both before it starts. The report
is `/tmp/scenario-hub-access-control-report.md`.
