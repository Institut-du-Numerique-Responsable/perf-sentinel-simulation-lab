#!/usr/bin/env python3
# Generate the fixtures for the path-id-masking scenario (product 0.44.0).
#
#   paths.ndjson      OTLP/JSON, outbound calls whose URL path carries an
#                     upper-case code, a hex id, a fixed word with a number,
#                     or an RPC service name. One service per shape.
#   endpoints.ndjson  OTLP/JSON, SQL N+1 under a SERVER span that carries
#                     url.path and no http.route (two dossiers), and under
#                     two http.route templates that differ by a version digit.
#   jaeger.json       Jaeger, SQL N+1 whose span carries http.target only.
#   zipkin.json       Zipkin v2, the same with http.target.
#
# baseline-0.43.2.json is not written here: it is `analyze --format json` of
# endpoints.ndjson by the published 0.43.2 binary, see README.md.
import json
import os

BASE_NS = 1_780_000_000_000_000_000
SERVER, CLIENT = 2, 3
OUT = os.path.dirname(os.path.abspath(__file__))

CODES = ["K7QX2P", "R4TN8W", "B3XK9M", "T8QW2Z", "H5LP7N", "X2MV4C"]
HEX_IDS = [f"507f1f77bcf86cd79943901{i}" for i in range(6)]


def attr(key, value):
    return {"key": key, "value": {"stringValue": value}}


def span(trace_id, num, parent, name, kind, start, dur, attrs):
    s = {
        "traceId": trace_id, "spanId": f"{num:016x}", "name": name, "kind": kind,
        "startTimeUnixNano": str(start), "endTimeUnixNano": str(start + dur),
        "attributes": [attr(k, v) for k, v in attrs], "status": {},
    }
    if parent:
        s["parentSpanId"] = parent
    return s


def doc(service, spans):
    return {"resourceSpans": [{
        "resource": {"attributes": [attr("service.name", service)]},
        "scopeSpans": [{"scope": {"name": "path-id-masking"}, "spans": spans}],
    }]}


def otlp_trace(index, service, root_attrs, children):
    """A SERVER root carrying `root_attrs`, then one CLIENT span per child."""
    trace_id = f"{index + 1:032x}"
    t0 = BASE_NS + index * 20_000_000_000
    root_num = (index + 1) * 1000
    spans = [span(trace_id, root_num, None, "root", SERVER, t0, 900_000_000, root_attrs)]
    parent = f"{root_num:016x}"
    for i, attrs in enumerate(children):
        start = t0 + 10_000_000 + i * 20_000_000
        spans.append(span(trace_id, root_num + 1 + i, parent, "call", CLIENT,
                          start, 3_000_000 + i * 400_000, attrs))
    return doc(service, spans)


def http_get(url):
    return [("http.request.method", "GET"), ("url.full", url)]


def sql(i):
    return [("db.system", "postgresql"),
            ("db.statement", f"SELECT * FROM dossier_line WHERE dossier_id = {i + 1}")]


def rpc():
    return [("rpc.system", "aws-api"), ("rpc.service", "WAFV2"),
            ("rpc.method", "ListWebACLs")]


route = [("http.route", "/api/batch")]
paths = [
    otlp_trace(0, "paths-codes", route,
               [http_get(f"http://crm-api/api/dossiers/{c}") for c in CODES]),
    otlp_trace(1, "paths-hex", route,
               [http_get(f"http://catalog-api/api/items/{h}") for h in HEX_IDS]),
    otlp_trace(2, "paths-fixed", route,
               [http_get("http://media-api/api/codec/H264")] * 6
               + [http_get("http://media-api/api/codec/H265")] * 6),
    otlp_trace(3, "paths-rpc", route, [rpc()] * 6),
]

endpoints = [
    otlp_trace(10, "crm-svc", [("url.path", "/api/dossiers/K7QX2P")],
               [sql(i) for i in range(8)]),
    otlp_trace(11, "crm-svc", [("url.path", "/api/dossiers/R4TN8W")],
               [sql(i) for i in range(8)]),
    otlp_trace(12, "jira-svc", [("http.route", "/rest/api/2/issue/{key}")],
               [sql(i) for i in range(8)]),
    otlp_trace(13, "jira-svc", [("http.route", "/rest/api/3/issue/{key}")],
               [sql(i) for i in range(8)]),
]

jaeger = {"data": [{
    "traceID": "00000000000000000000000000000021",
    "spans": [{
        "traceID": "00000000000000000000000000000021",
        "spanID": f"{0x2100 + i:016x}", "operationName": "query",
        "references": [], "startTime": 1_780_000_400_000_000 + i * 20_000,
        "duration": 3_000 + i * 400, "processID": "p1",
        "tags": [{"key": "db.system", "value": "postgresql"},
                 {"key": "db.statement",
                  "value": f"SELECT * FROM order_line WHERE order_id = {i + 1}"},
                 {"key": "http.target", "value": "/api/orders/42"}],
    } for i in range(8)],
    "processes": {"p1": {"serviceName": "jaeger-svc"}},
}]}

zipkin = [{
    "traceId": "00000000000000000000000000000031", "id": f"{0x3100 + i:016x}",
    "name": "query", "kind": "CLIENT",
    "timestamp": 1_780_000_500_000_000 + i * 20_000, "duration": 3_000 + i * 400,
    "localEndpoint": {"serviceName": "zipkin-svc"},
    "tags": {"db.system": "postgresql",
             "db.statement": f"SELECT * FROM order_line WHERE order_id = {i + 1}",
             "http.target": "/api/orders/43"},
} for i in range(8)]


def write_ndjson(name, docs):
    with open(os.path.join(OUT, name), "w") as fh:
        for d in docs:
            fh.write(json.dumps(d) + "\n")


write_ndjson("paths.ndjson", paths)
write_ndjson("endpoints.ndjson", endpoints)
with open(os.path.join(OUT, "jaeger.json"), "w") as fh:
    json.dump(jaeger, fh, indent=1)
with open(os.path.join(OUT, "zipkin.json"), "w") as fh:
    json.dump(zipkin, fh, indent=1)
