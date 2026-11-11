# path-id-masking

The path id masking of perf-sentinel 0.44.0 on the batch path: URL path
templates, `source.endpoint` taken from a raw URL, `report --before` against an
older baseline, and the warning on an acknowledgment written on a raw path.

## Why it exists

On a production daemon, a batch read thousands of dossiers by their number
(`/api/dossiers/K7QX2P`). Each number became its own template and its own
signature: one call made up 1,137 of the Hub's new signatures in an hour, and the
detection ledger overflowed its 10,000 signatures every evening. 0.44.0 masks an
upper-case code and a hex id as `{id}`, and masks the ids of a `source.endpoint`
that ingestion took from `url.path`, `http.target`, `http.url` or `url.full`
for want of `http.route`. The engine's unit tests call the normalizer on
strings, so nothing else drives the rule through the three trace formats, the
report diff and the acknowledgment warning together.

## What it asserts

| id  | assertion |
|-----|-----------|
| P1  | six dossier codes read one by one (`K7QX2P`, `R4TN8W`, ...) are one `n_plus_one_http` on `GET crm-api/api/dossiers/{id}` |
| P2  | six Mongo ObjectIds read one by one are one `n_plus_one_http` on `GET catalog-api/api/items/{id}` |
| P3  | six calls to `/api/codec/H264` and six to `/api/codec/H265` stay two `redundant_http` findings |
| P4  | an RPC call on `rpc.service = WAFV2` keeps the template `aws-api WAFV2/ListWebACLs` |
| E1  | a SERVER span with `url.path = /api/dossiers/K7QX2P` and no `http.route` gives the endpoint `/api/dossiers/{id}` over OTLP |
| E1b | the two dossiers share one signature |
| E2  | `http.route` templates `/rest/api/2/issue/{key}` and `/rest/api/3/issue/{key}` stay two endpoints |
| E3  | a Jaeger span with `http.target = /api/orders/42` gives `/api/orders/{id}` |
| E4  | a Zipkin span with `http.target = /api/orders/43` gives `/api/orders/{id}` |
| D0  | the committed baseline holds the raw endpoints, so D1 to D3 compare something |
| D1  | `report --before baseline-0.43.2.json` lists no new finding |
| D2  | nor a resolved one |
| D3  | nor an endpoint delta |
| K1  | an ack on the 0.43.2 signature of `/api/dossiers/K7QX2P` warns with the masked signature and `re-acknowledge` |
| K2  | the finding still fires: the ack does not carry over to the new signature |
| W1  | a loopback `watch` fed `endpoints.ndjson` over OTLP/protobuf serves `/api/dossiers/{id}` on `/api/findings` |
| W2  | its `/api/detections` counts the two dossiers on one row, `detections = 2` |
| W3  | the two `http.route` versions keep two rows |

## Fixtures

`fixtures/generate.py` writes `paths.ndjson`, `endpoints.ndjson` (OTLP/JSON),
`jaeger.json` and `zipkin.json`. `baseline-0.43.2.json` is the output of the
published 0.43.2 macOS arm64 binary (`SHA256SUMS.txt` checked) on
`endpoints.ndjson`:

```bash
perf-sentinel analyze --input fixtures/endpoints.ndjson --no-acknowledgments \
  --format json > fixtures/baseline-0.43.2.json
```

## Run

```bash
make verify-path-id-masking
```

A local release binary, python3 with `opentelemetry-proto`, no cluster, about 10
seconds. The W legs start a throwaway daemon on loopback ports 14958 and 14957
(`PIM_DAEMON_HTTP_PORT`, `PIM_DAEMON_GRPC_PORT`). Set `PERF_SENTINEL_LOCAL_BIN`
to test another binary.

## Control

Against 0.43.2, P1, P2, E1, E1b, E3, E4, W1, W2, K1 and K2 fail: the codes and
hex ids give one template per value, so no N+1 fires, the endpoints keep their
raw segment, the ledger counts each dossier on its own row, and the ack matches
its finding. P3, P4, E2, W3 and D0 to D3 pass on both.
