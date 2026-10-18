#!/usr/bin/env python3
# Generate the native perf-sentinel SpanEvent fixtures for the
# sql-backtick-redaction scenario (0.9.2 normalize/sql.rs changes).
#
# Two files, each a JSON array of native SpanEvent objects (the shape
# `analyze --input` auto-detects). The native batch path normalizes the
# `target` SQL, so these fixtures exercise normalize/sql.rs directly with
# NO cluster and NO daemon.
#
#   backtick.native.json
#     One trace, six SQL children sharing ONE normalized template but
#     differing in the bound `id` literal (1..6) -> a real N+1 group
#     (distinct_params >= n_plus_one_min_occurrences=5, mode-independent).
#     Asserts MySQL backtick identifiers are preserved. The table name is
#     the NUMERIC identifier `2024` (a year-partitioned table): without the
#     0.9.2 InBacktick tokenizer state the 2024 between backticks would be
#     extracted as a numeric literal and masked to `?`, so this column is
#     the real discriminator. `col2` additionally guards alphanumeric ids.
#
#   array-redaction.native.json
#     One trace, six SQL children. The PostgreSQL array/subscript string
#     literals ARRAY['secret','pii'] and data['ssn'] must be MASKED to ?
#     in the normalized template (the most important 0.9.2 security fix):
#     no string literal may leak into analyze output. A distinct owner id
#     (1..6) makes the group an N+1 so a finding is guaranteed to fire and
#     carry the masked pattern.template.
#
#   double-quote.otlp.json  (0.25.5)
#     OTLP JSON, CLIENT spans carrying db.statement plus the engine attribute.
#     Four traces of six spans each, distinct values 1..6 -> one N+1 per trace:
#       A  db.system=mysql        WHERE email = "alice-<n>@example.com"
#       B  db.system=mariadb      same statement
#       D  db.system.name=mysql   same statement, stable semconv key only
#       C  db.system=postgresql   SELECT "Name" FROM "Users" WHERE "Id" = <n>
#     MySQL and MariaDB read "..." as a string literal, so A, B and D must mask
#     it to ? (and the address must never reach the output). PostgreSQL reads
#     it as an identifier, so C keeps the quoted names verbatim.
#
#   double-quote-gap.native.json  (0.25.5)
#     Native JSON whose `operation` is the SQL verb names no engine, so the
#     double-quoted value is kept: the documented gap, pinned so a silent
#     change of the default shows up.
#
#   literal-forms.otlp.json  (0.31.3)
#     OTLP JSON, four traces of six CLIENT spans, distinct values 1..6:
#       E1  db.system=mysql       WHERE note = 'it\'s secret-<n>'
#       E2  no engine attribute   same statement
#       E3  db.system=mssql       WHERE path = 'C:\Temp\' AND owner = 'owner-<n>@corp.test'
#       E4  db.system=postgresql  WHERE h = 0x<n>F AND v = <n>.5e-3
#     E1 and E2 read the backslash as an escape, E3 as an ordinary character
#     (SQL Server strings follow the standard). E4's hex and exponent values
#     collapse to one ? each. Before 0.31.3 every trace split into one
#     template per value and secret-<n> reached the template.
#
# stdlib-only. Regenerating needs no extra packages. verify.sh consumes the
# committed *.native.json and double-quote.otlp.json directly and never runs
# this generator.
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_NS = 1_749_297_600_000_000_000


def iso_ts(ns):
    # mirrors tracegen.iso_ts (UTC, millisecond precision, trailing Z)
    import datetime

    dt = datetime.datetime.fromtimestamp(ns / 1e9, tz=datetime.timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (ns // 1_000_000 % 1000)


def sql_event(trace_hex, sid, parent_sid, offset_ms, statement, endpoint, duration_us=2000):
    start = BASE_NS + offset_ms * 1_000_000
    return {
        "timestamp": iso_ts(start),
        "trace_id": "t%032x" % trace_hex,
        "span_id": "s%016x" % ((trace_hex << 20) | sid),
        "parent_span_id": "s%016x" % ((trace_hex << 20) | parent_sid),
        "service": "shop-mysql",
        "cloud_region": "eu-west-3",
        "type": "sql",
        "operation": statement.split(None, 1)[0].upper(),
        "target": statement,
        "duration_us": duration_us,
        "source": {"endpoint": endpoint, "method": "Handler::handle"},
    }


def build_backtick():
    # MySQL backtick identifiers, one per id 1..6. `col2` carries an internal
    # digit that must survive (not be tokenized as the literal 2).
    events = []
    for i in range(1, 7):
        stmt = "SELECT `name`, `col2` FROM `2024` WHERE `id` = %d" % i
        events.append(sql_event(0xB1, i + 1, 1, 2 + i * 4, stmt, "GET /api/users/{id}"))
    return events


def build_array_redaction():
    # PostgreSQL array + subscript string literals. They MUST be masked.
    # owner id 1..6 -> distinct params -> guaranteed N+1 finding.
    events = []
    for i in range(1, 7):
        stmt = (
            "SELECT * FROM t WHERE owner = %d "
            "AND tags = ARRAY['secret', 'pii'] AND data['ssn'] IS NOT NULL" % i
        )
        events.append(sql_event(0xA2, i + 1, 1, 2 + i * 4, stmt, "GET /api/audit"))
    return events


def otlp_span(trace_hex, i, statement, engine_key, engine):
    start = BASE_NS + (2 + i * 4) * 1_000_000
    return {
        "traceId": "%032x" % trace_hex,
        "spanId": "%016x" % ((trace_hex << 20) | (i + 1)),
        "parentSpanId": "%016x" % ((trace_hex << 20) | 1),
        "name": "SELECT",
        "kind": 3,
        "startTimeUnixNano": str(start),
        "endTimeUnixNano": str(start + 2_000_000),
        "attributes": [
            {"key": engine_key, "value": {"stringValue": engine}},
            {"key": "db.statement", "value": {"stringValue": statement}},
        ],
    }


def build_double_quote_otlp():
    email = 'SELECT * FROM users WHERE email = "alice-%d@example.com"'
    pg = 'SELECT "Name" FROM "Users" WHERE "Id" = %d'
    spans = []
    for trace_hex, key, engine, stmt in (
        (0xDA, "db.system", "mysql", email),
        (0xDB, "db.system", "mariadb", email),
        (0xDD, "db.system.name", "mysql", email),
        (0xDC, "db.system", "postgresql", pg),
    ):
        spans += [otlp_span(trace_hex, i, stmt % i, key, engine) for i in range(1, 7)]
    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [{"key": "service.name", "value": {"stringValue": "shop-users"}}]
                },
                "scopeSpans": [{"scope": {"name": "lab"}, "spans": spans}],
            }
        ]
    }


def build_double_quote_gap():
    return [
        sql_event(0xDE, i + 1, 1, 2 + i * 4,
                  'SELECT * FROM users WHERE email = "gap-%d@native.test"' % i,
                  "GET /api/users")
        for i in range(1, 7)
    ]


def build_literal_forms_otlp():
    note = "SELECT * FROM users WHERE note = 'it\\'s secret-%d'"
    path = "SELECT * FROM files WHERE path = 'C:\\Temp\\' AND owner = 'owner-%d@corp.test'"
    spans = []
    for trace_hex, key, engine, stmt in (
        (0xE1, "db.system", "mysql", note),
        (0xE2, None, None, note),
        (0xE3, "db.system", "mssql", path),
    ):
        for i in range(1, 7):
            span = otlp_span(trace_hex, i, stmt % i, key, engine)
            if key is None:
                span["attributes"] = span["attributes"][1:]
            spans.append(span)
    spans += [
        otlp_span(0xE4, i, "SELECT * FROM metrics WHERE h = 0x%dF AND v = %d.5e-3" % (i, i),
                  "db.system", "postgresql")
        for i in range(1, 7)
    ]
    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [{"key": "service.name", "value": {"stringValue": "shop-users"}}]
                },
                "scopeSpans": [{"scope": {"name": "lab"}, "spans": spans}],
            }
        ]
    }


def main():
    for name, events in (
        ("backtick.native.json", build_backtick()),
        ("array-redaction.native.json", build_array_redaction()),
        ("double-quote.otlp.json", build_double_quote_otlp()),
        ("double-quote-gap.native.json", build_double_quote_gap()),
        ("literal-forms.otlp.json", build_literal_forms_otlp()),
    ):
        path = os.path.join(HERE, name)
        with open(path, "w") as fh:
            json.dump(events, fh, indent=2)
            fh.write("\n")
        print("%s  written" % name)


if __name__ == "__main__":
    main()
