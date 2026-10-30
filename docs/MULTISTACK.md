# Multistack service contract

This document is the canonical contract every multistack service in this
lab must respect. The lab runs 3 Java/Spring Boot services:
`order-service`, `payment-service` and `notification-service`. It also
runs 15 additional services across distinct stacks: Quarkus,
Quarkus+Mutiny, Helidon SE, Helidon MP, .NET 10, Rust+Diesel,
Rust+SeaORM, NestJS, Django, FastAPI, Go, Rails, Laravel, Symfony and
Kotlin+Ktor.

Together these are **18 deployable services across 16 stacks**: one Spring
Boot/JPA baseline implemented by three cooperating services and 15 independent
multistack services. Every stack satisfies the same 12-type perf-sentinel
contract across SQL, HTTP and RabbitMQ.

## HTTP contract: 12 fault endpoints + 3 business endpoints

### Fault endpoints (the 12 anti-patterns)

Each multistack service MUST expose all 12 endpoints below, with the exact path, method,
query parameter, and JSON response shape. Behaviour is stack-specific but
must produce the corresponding finding type when scraped by perf-sentinel
through the cluster OTel Collector.

| Method | Path                         | Query param (default)   | Anti-pattern produced |
|--------|------------------------------|-------------------------|-----------------------|
| POST   | `/api/fault/n-plus-one-sql`  | `items=15`              | `n_plus_one_sql`      |
| POST   | `/api/fault/n-plus-one-http` | `recipients=10`         | `n_plus_one_http`     |
| POST   | `/api/fault/n-plus-one-messaging` | `messages=8&broker=rabbitmq` | `n_plus_one_messaging` |
| POST   | `/api/fault/redundant-sql`   | `repeats=10`            | `redundant_sql`       |
| POST   | `/api/fault/redundant-http`  | `repeats=10`            | `redundant_http`      |
| POST   | `/api/fault/slow-sql`        | `delayMs=600&repeats=6` | `slow_sql`            |
| POST   | `/api/fault/slow-http`       | `delayMs=600&repeats=6` | `slow_http`           |
| POST   | `/api/fault/slow-messaging`  | `delayMs=600&repeats=3&broker=rabbitmq` | `slow_messaging` |
| POST   | `/api/fault/fanout`          | `width=40`              | `excessive_fanout`    |
| POST   | `/api/fault/chatty`          | `calls=30`              | `chatty_service`      |
| POST   | `/api/fault/serialized`      | `steps=6`               | `serialized_calls`    |
| POST   | `/api/fault/pool-saturation` | `concurrency=20`        | `pool_saturation`     |

`order-service` carries one endpoint beyond this contract,
`POST /api/fault/template-mutation-sql?shape=a|b&items=N` (default 12,
the scenario sends 15). It is
deliberately **not** part of the 12: it exists for a single scenario,
[`hub-lineage-mutation`](../scenarios/hub-lineage-mutation), which needs the
same detector, service and endpoint to produce two different SQL templates.
Nothing requires the other stacks to implement it.

Valid, successful fault requests return HTTP 200 with the JSON shape below.
Validation and dependency failures follow the 400/non-200 contract documented
below.

### Response shape

```json
{
  "antiPattern": "n_plus_one_sql",
  "service": "quarkus-svc",
  "durationMs": 245,
  "details": { "...stack-specific keys..." },
  "timestamp": "2026-05-24T10:45:30.123Z"
}
```

Required fields:

- `antiPattern` (string): exact snake_case name matching the finding
  type.
- `service` (string): must equal `OTEL_SERVICE_NAME`.
- `durationMs` (integer): wall-clock duration of the fault.
- `details` (object): stack-specific. At minimum the input parameter and
  a count of operations performed (e.g.
  `{"items": 15, "rows_seen": 75}`). Messaging responses additionally
  require `published == confirmed ==` the requested message count.
- `timestamp` (ISO-8601, UTC): instant the response is built.

### Behaviour notes per anti-pattern

These are the invariants the perf-sentinel detectors rely on. Reproduce them
faithfully in the stack-specific ORM/HTTP client, not "something that looks
similar".

- `n-plus-one-sql`: loop of N distinct SQL statements (interpolated
  literals, not prepared parameters), e.g.
  `SELECT count(*) FROM <schema>.order_items WHERE order_id = 1`,
  `WHERE order_id = 2`, …. Each statement must reach the JDBC/driver
  layer as a separate template so the OTel instrumentation emits N
  distinct spans.
- `redundant-sql`: loop of N identical SQL statements with identical
  literal parameters, e.g.
  `SELECT count(*) FROM <schema>.payments WHERE customer_id = 1` repeated
  10 times. The sanitizer must see one template repeated.
- `slow-sql`: N statements each delayed server-side via
  `SELECT pg_sleep(0.6)` (or driver-equivalent), interpolated literals so
  each is distinct.
- `pool-saturation`: pool size must be capped at 10 in the stack's
  connection pool config (Hikari for Spring, Agroal for Quarkus, EFCore
  pool, etc.). Then launch `concurrency=20` parallel tasks each holding a
  connection ~400ms, so 10 tasks queue behind 10 in-flight ones.
- `n-plus-one-http`: N outbound HTTP calls to a local endpoint, each with
  a distinct query template (e.g.
  `/api/external/mock?recipient=1, =2, …`).
- `redundant-http`: N identical outbound HTTP calls, same URL same
  params.
- `slow-http`: N outbound HTTP calls to `/api/external/mock?delayMs=600`.
- `fanout`: N parallel outbound HTTP calls (executor / virtual threads /
  Promise.all / tokio::join_all / goroutines), each to
  `/api/external/mock?delayMs=10`.
- `chatty`: N sequential outbound calls with varying templates
  (`?seq={i}&op={i%7}`). Distinct templates avoid the n+1 classification.
- `serialized`: 6 sequential calls to `/api/dispatch/email`, `…/sms`,
  `…/push`, `…/webhook`, `…/slack`, `…/teams`, each `delayMs=80`, so the
  total wall-clock crosses ~480ms.
- `n-plus-one-messaging`: accepts only RabbitMQ with
  `5 <= messages <= 100`, publishes distinct persistent messages to the
  stack's durable direct `perfsim.<service>` destination, then waits once
  for all broker confirms.
- `slow-messaging`: accepts only RabbitMQ with `501 <= delayMs <= 5000`
  and `3 <= repeats <= 20`. It applies the existing Toxiproxy downstream
  latency, then alternates each real publication with its broker confirm.

Invalid messaging input returns HTTP 400 before any RabbitMQ or Toxiproxy
call. A partial publication, nack, returned message, absent confirmation,
unavailable dependency or Toxiproxy failure returns non-200.

### RabbitMQ and telemetry contract

RabbitMQ and Toxiproxy run in the `messaging` namespace. Every service
uses the shared ports 5672, 25672 and 8474, queue TTL 60000 ms and the
local `rabbitmq-credentials` Secret. Usernames and passwords are injected
only through `secretKeyRef`. They never appear in values files or source
code.

Native client instrumentation is retained when it covers the real publish and
confirmation boundary. Otherwise a manual `PRODUCER` span named
`perfsim.<service> send` surrounds the real operation and carries only
`messaging.system`, `messaging.destination.name` and
`messaging.operation.type`. No service emits `code.*` attributes.

### Business endpoints (cross-service reach)

Each service exposes a small business surface that other services (or its
own fault endpoints) can call to exercise HTTP-side anti-patterns without
depending on cross-service infrastructure. Method is `GET`, content type is
`application/json`.

| Path                      | Query params                 | Purpose                                                                                                                                                       |
|---------------------------|------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `/api/external/mock`      | `delayMs={d}&seq={i}&op={n}` | Light parameterized endpoint, used by `n-plus-one-http`, `chatty`, `fanout`, `slow-http`. Server sleeps `delayMs` milliseconds before returning a small JSON. |
| `/api/dispatch/{channel}` | `delayMs={d}`                | Six channels (`email`, `sms`, `push`, `webhook`, `slack`, `teams`), each with the same delay-then-respond behaviour. Used by `serialized`.                    |
| `/api/payments/history`   | `customerId={id}&limit={n}`  | Returns up to `limit` payment rows for a customer from this service's schema. Used by `redundant-http`.                                                       |

These keep each service self-sufficient: a stack's HTTP-side fault endpoints
call back into its own business surface, so the fault works even if no other
multistack service is deployed.

### Health endpoints

Every service MUST expose:

- `GET /q/health/live` (or stack-equivalent: `/actuator/health/liveness`,
  `/health`, `/healthz`, etc.): HTTP 200 when the process is up.
- `GET /q/health/ready` (or equivalent): HTTP 200 when the connection
  pool is initialised and the schema migrations have run.

The Kubernetes deployment manifest wires these into `livenessProbe` /
`readinessProbe` with a 5s initial delay and a 10s period. Stack-specific
paths are documented in each service's `README.md`.

## Service inventory

The lab namespace `shop` hosts all services. New stacks land on ports 8083
through 8097 (Java baseline keeps 8080-8082). Each service owns its own
Postgres schema in the shared `lab` database.

| Service              | Port | Schema        | Effective stack                                      |
|----------------------|------|---------------|------------------------------------------------------|
| order-service        | 8080 | orders        | Spring Boot 4.0.6 + JPA                             |
| payment-service      | 8081 | payments      | Spring Boot 4.0.6 + JPA                             |
| notification-service | 8082 | notifications | Spring Boot 4.0.6 + JPA                             |
| quarkus-svc          | 8083 | quarkus       | Quarkus 3.33.1.1 LTS + Panache                      |
| mutiny-svc           | 8084 | mutiny        | Quarkus 3.33.1.1 LTS + Mutiny                       |
| helidon-se-svc       | 8085 | helidon_se    | Helidon SE 4.4.0                                    |
| helidon-mp-svc       | 8086 | helidon_mp    | Helidon MP 4.4.0 + JPA                              |
| dotnet-svc           | 8087 | dotnet        | .NET 10 + EF Core 10.0.10                           |
| diesel-svc           | 8088 | diesel        | Rust 1.97 + Diesel 2.3.12                           |
| seaorm-svc           | 8089 | seaorm        | Rust 1.97 + SeaORM 1.1.20                           |
| nest-svc             | 8090 | nest          | NestJS 11.1.28 + Prisma 6.19.3                      |
| django-svc           | 8091 | django        | Django 5.2.17 LTS + psycopg 3.3.4                   |
| fastapi-svc          | 8092 | fastapi       | FastAPI 0.141.1 + SQLAlchemy 2.0.51 async           |
| go-svc               | 8093 | go            | Go 1.26 + pgx 5.10.0                                |
| rails-svc            | 8094 | rails         | Rails 8.1.3.1 + Active Record (Ruby 4.0)            |
| laravel-svc          | 8095 | laravel       | Laravel 13.25.0 + Eloquent (PHP 8.5, native OTel)   |
| symfony-svc          | 8096 | symfony       | Symfony 7.4.16 LTS + Doctrine 3.6.8 (PHP 8.5)       |
| ktor-svc             | 8097 | ktor          | Ktor 3.5.1 + Kotlin 2.4.10                          |

The two PHP members exercise perf-sentinel's framework-aware
`suggested_fix`. Laravel's app-wide
`io.opentelemetry.contrib.php.laravel` scope tags every finding
`php_laravel_eloquent`. Symfony's DB-specific
`io.opentelemetry.contrib.php.doctrine` scope tags only SQL findings
`php_doctrine`, and non-SQL Symfony findings fall through to
`php_generic`. Both use the same 12-endpoint contract.

Cluster-internal DNS:
`http://<svc-name>.shop.svc.cluster.local:<port>`.

### Effective versions (verified 2026-08-09)

This is an inventory of the versions resolved by the committed manifests,
lockfiles, and Dockerfiles. It does not claim that they are the latest or
recommended upstream versions. Runtime image tags that intentionally track a
patch line are shown at the precision committed in the repository.

| Stack (services) | Effective framework and runtime | Effective data, messaging, and telemetry dependencies |
|------------------|---------------------------------|-------------------------------------------------------|
| Spring Boot / JPA (`order-service`, `payment-service`, `notification-service`) | Spring Boot 4.0.6; Java 25 / Temurin 25.0.3_9; Hibernate 7.2.12.Final | PostgreSQL JDBC 42.7.4; Flyway 11.0.0; RabbitMQ Java 5.27.1; OTel Java agent 2.30.0 |
| Quarkus Panache (`quarkus-svc`) | Quarkus 3.33.1.1 LTS; Java 25 / Temurin 25.0.3_9; Hibernate 7.2.6.Final | PostgreSQL JDBC 42.7.10; RabbitMQ Java 5.27.1; Quarkus OTel extension + OTel Java agent 2.30.0 |
| Quarkus Mutiny (`mutiny-svc`) | Quarkus 3.33.1.1 LTS; Mutiny 3.2.0; Java 25 / Temurin 25.0.3_9 | Vert.x PG client 4.5.26; RabbitMQ Java 5.27.1; native Quarkus OTel extension |
| Helidon SE (`helidon-se-svc`) | Helidon SE 4.4.0; Java 25 / Temurin 25.0.3_9 | HikariCP 6.0.0; Flyway 11.7.2; PostgreSQL JDBC 42.7.2; RabbitMQ Java 5.27.1; OTel Java agent 2.30.0 |
| Helidon MP (`helidon-mp-svc`) | Helidon MP 4.4.0 / MicroProfile 6.1; Java 25 / Temurin 25.0.3_9 | Hibernate 6.3.1.Final; HikariCP 5.0.1; Flyway 11.7.2; PostgreSQL JDBC 42.7.2; RabbitMQ Java 5.27.1; OTel Java agent 2.30.0 |
| Kotlin / Ktor (`ktor-svc`) | Kotlin 2.4.10; Ktor 3.5.1; Java 25 / Temurin 25.0.3_9 | Exposed 2.0.18; HikariCP 6.0.0; PostgreSQL JDBC 42.7.4; Flyway 11.7.2; RabbitMQ Java 5.27.1; OTel API 1.51.0 + Java agent 2.30.0 |
| .NET / EF Core (`dotnet-svc`) | .NET 10 (`net10.0`); EF Core 10.0.10 | Npgsql EF 10.0.3; RabbitMQ.Client 7.2.2; OTel stable packages 1.17.0, EF instrumentation 1.15.1-beta.1 |
| Rust / Diesel (`diesel-svc`) | Rust 1.97; axum 0.8.9; Diesel 2.3.12 | Lapin 4.10.0; OTel Rust 0.32.0; tracing-opentelemetry 0.33.0; axum-tracing-opentelemetry 0.38.0 |
| Rust / SeaORM (`seaorm-svc`) | Rust 1.97; axum 0.8.9; SeaORM 1.1.20 | Lapin 4.10.0; OTel Rust 0.32.0; tracing-opentelemetry 0.33.0; axum-tracing-opentelemetry 0.38.0 |
| NestJS / Node (`nest-svc`) | Node.js 24; NestJS 11.1.28; Prisma/client 6.19.3 | amqplib 2.0.1; pg 8.21.0; OTel sdk-node/HTTP/OTLP 0.221.0, trace-node 2.10.0, pg instrumentation 0.73.0 |
| Django (`django-svc`) | Python 3.14; Django 5.2.17 LTS | psycopg 3.3.4; Pika 1.3.2; OTel SDK/exporter 1.44.0, instrumentations 0.65b0 |
| FastAPI (`fastapi-svc`) | Python 3.14; FastAPI 0.141.1; Pydantic 2.13.4 | SQLAlchemy 2.0.51; asyncpg 0.31.0; aio-pika 9.6.2; OTel SDK/exporter 1.44.0, instrumentations 0.65b0 |
| Go / pgx (`go-svc`) | Go 1.26; chi 5.3.1; pgx 5.10.0 | amqp091-go 1.13.0; OTel Go 1.45.0; otelhttp 0.70.0; otelpgx 0.11.1 |
| Rails (`rails-svc`) | Ruby 4.0; Rails/Active Record 8.1.3.1 | Bunny 3.1.0; pg 1.6.3; Puma 8.0.2; OTel SDK 1.13.0, OTLP 0.34.1, Rails 0.42.0, Active Record 0.13.0 |
| Laravel (`laravel-svc`) | PHP 8.5; Laravel 13.25.0 | php-amqplib 3.7.4; OTel SDK 1.15.0, Laravel 1.8.0, PDO 0.5.0, PECL extension 1.2.1 |
| Symfony (`symfony-svc`) | PHP 8.5; Symfony 7.4.16 LTS; Doctrine ORM 3.6.8 | php-amqplib 3.7.4; OTel SDK 1.15.0, Symfony 1.4.0, Doctrine/PDO 0.5.0, PECL extension 1.2.1 |

## Postgres conventions

The `lab` database is shared. Each service owns its schema, named exactly as
the service slug without the `-svc` suffix (e.g. `quarkus`, `helidon_se`).
Underscores replace hyphens since SQL identifiers cannot contain hyphens
without quoting.

Each schema MUST contain at minimum three tables that match the Java
baseline's shape, so the fault endpoints can target consistent queries:

- `<schema>.orders`: at least 100 rows, columns `id` (PK), `customer_id`,
  `total_cents`, `status`, `created_at`.
- `<schema>.order_items`: at least 500 rows (5 per order on average),
  columns `id` (PK), `order_id` (FK), `product_id`, `quantity`,
  `unit_cents`.
- `<schema>.payments`: at least 200 rows, columns `id` (PK), `order_id`,
  `customer_id`, `amount_cents`, `status`, `created_at`.

Seed data is the responsibility of the service's own migration tool (Flyway,
EF Core migrations, diesel-cli, sea-orm-cli, Prisma migrate, django migrate,
alembic, golang-migrate, Active Record / a startup bootstrap).

The shared schema bootstrap (schema + role + GRANT + search_path) for the 15
new services lives in `manifests/postgres-multistack-schemas.yaml` as a
Kubernetes Job. It must be applied once before any new service comes up,
and is idempotent (`CREATE SCHEMA IF NOT EXISTS`, `CREATE ROLE` guarded by
`pg_roles` lookup).

## OpenTelemetry wiring

Every service MUST export traces (only traces, not logs or metrics) to the
shared OTel Collector via OTLP HTTP/protobuf. The Collector then forwards
to perf-sentinel on the cluster.

Environment variables to set on each service container:

```
OTEL_SERVICE_NAME=<svc-name>
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector-opentelemetry-collector.observability.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_SAMPLER=always_on
OTEL_LOGS_EXPORTER=none
OTEL_METRICS_EXPORTER=none
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,deployment.environment=lab,cloud.region=eu-west-3,cloud.provider=aws
```

Stack-specific instrumentation choice:

- **Spring Boot baseline**: OTel Java agent 2.30.0.
- **Quarkus Panache**: `quarkus-opentelemetry` plus OTel Java agent 2.30.0.
- **Quarkus Mutiny**: native `quarkus-opentelemetry`, without the Java agent.
- **Helidon SE / MP** and **Ktor**: OTel Java agent 2.30.0.
- **.NET 10**: `OpenTelemetry.AspNetCore` + `OpenTelemetry.Instrumentation.EntityFrameworkCore`
  + `OpenTelemetry.Exporter.OpenTelemetryProtocol`, configured in `Program.cs`
  via the `ResourceBuilder` and `TracerProviderBuilder` chain.
- **Rust** (Diesel / SeaORM): `opentelemetry` 0.32 +
  `tracing-opentelemetry` 0.33 + `opentelemetry-otlp`, initialised at
  startup. The HTTP layer uses `axum-tracing-opentelemetry` 0.38.
- **NestJS**: `@opentelemetry/sdk-node` 0.221 configured at `main.ts` boot.
- **Django / FastAPI**: `opentelemetry-instrumentation-django` /
  `opentelemetry-instrumentation-fastapi` + `opentelemetry-instrumentation-psycopg`
  / `opentelemetry-instrumentation-sqlalchemy`.
- **Rails**: OTel SDK + Rails, Active Record, Net::HTTP, and pg instrumentations.
- **Laravel / Symfony**: OTel PHP SDK, framework/PDO instrumentation, and the
  PECL extension pinned to 1.2.1.
- **Go**: `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp`
  middleware + `github.com/exaring/otelpgx` tracing.

## Process map (perf-sentinel Scaphandre integration)

Every service MUST appear in `manifests/perf-sentinel-daemon.yaml` under
`[green.scaphandre.process_map]` with `exe_contains` matching the runtime's
absolute path:

- Java distroless: `exe_contains = "bin/java"`
- .NET chiseled: `exe_contains = "/dotnet"`
- Rust static: `exe_contains = "/usr/local/bin/<svc>-bin"` (path of compiled binary)
- Node distroless: `exe_contains = "bin/node"`
- Python distroless: `exe_contains = "bin/python3"`
- Go static: `exe_contains = "/usr/local/bin/<svc>-bin"`
- Ruby slim: `exe_contains = "bin/ruby"`

`cmdline_contains` is the service slug (e.g. `quarkus-svc`) so identical
runtimes (multiple Java services) stay disambiguated. The Scaphandre mock at
`manifests/scaphandre-mock.yaml` exposes a corresponding fictional process
per service so the sub-test 7 of `scaphandre-mock-validation` keeps passing.

## Network policies

The intra-shop NetworkPolicy in `manifests/network-policies.yaml` (rule
`shop-intra-namespace`) covers ports 8080-8097 for ingress between pods in
the `shop` namespace. Any pod arboring `app.kubernetes.io/part-of:
perf-sentinel-lab` inherits Postgres + OTel Collector egress for free.

No new NetworkPolicy needs to ship per stack as long as the port stays in
range and the label is set.

## Validation contract

Per-stack validation flow (run in sequence by the multistack harness):

1. `make seed-<stack>-svc` builds the image, applies the Helm chart, and
   waits for `Ready=True`.
2. `scripts/run-multistack-scenario.sh <stack>` creates one guarded k6 Job per
   fault and drives all 12 endpoints in the fixed global order.
3. Before every Job the runner snapshots existing `(trace_id,
   source_endpoint)` pairs. A PASS requires a new trace, the exact service and
   source endpoint, and the framework expectation where one is defined.
4. Messaging findings additionally require the exact `rabbitmq
   perfsim.<service>` destination, at least 8 direct occurrences, or at least
   3 slow occurrences with p50 above 500000 microseconds.
5. The k6 contract also asserts `details.calls_ok == details.calls_made` on every
   response that reports them. A fault endpoint whose self-calls time out still
   answers 200, so without this the load passes and only the missing finding
   surfaces, 40s later and unexplained. Stacks that expose neither field are
   unaffected.
6. After a CI failure, replay only the phases that failed instead of the full
   twelve: `ONLY_PATTERNS="redundant_http:5:30s" scripts/run-multistack-scenario.sh
   laravel` (space-separated `pattern:vus:duration` entries, same order semantics).

Every one of the 15 multistack services must pass 12/12, for a blocking
aggregate of 180/180. The three Spring services form a separate baseline
validation unit that must also pass its distributed 12/12 suite. Thus all 18
deployable services are covered without pretending the Spring services each
expose all 12 routes independently.

## Stack-specific release notes

Notes captured at planning time. Each section accumulates as the stack lands.

### Helidon 4.4.0 (2026-03-17)

Source: [Helidon 4.4.0 release announcement](https://medium.com/helidon/helidon-4-4-0-released-d10be2fb8039).
Key points for the phase 3 (Helidon MP) and phase 4 (Helidon SE) deliveries:

- **LTS confirmed**: Helidon 4.4 is now an LTS release covered by Oracle's
  Java Verified Portfolio (JVP). The lab pins 4.4.0 with confidence.
- **Tip and Tail model**: future Helidon releases adopt OpenJDK's
  Tip-and-Tail. Helidon 4.4 is the Tail (LTS), and the next major
  (Helidon 27) will track JDK 27 with the Tip cadence. Bumping the lab
  past 4.4 is a deliberate Sept-2026+ decision, not a routine patch.
- **Java 21 minimum, Java 25 recommended**: Helidon 4.4 runs on the same
  `gcr.io/distroless/java25-debian12` image the Java baseline uses.
- **OpenTelemetry exporter**: the upstream OTel release Helidon 4.4 ships
  with no longer includes the Jaeger exporter. Helidon's Jaeger tracing
  provider is deprecated. **Lab choice**: stick with OTLP HTTP/protobuf
  exporter (`http://otel-collector-opentelemetry-collector.observability...`),
  consistent with the contract documented above.
- **Metrics & logs over OTel**: Helidon 4.4 adds OTLP-exportable metrics
  and OTel-aligned logging. Lab only ships traces (`OTEL_METRICS_EXPORTER=none`,
  `OTEL_LOGS_EXPORTER=none`), so this is informational only.
- **CORS config moved**: feature-level CORS config is deprecated. The new
  centralized top-level config is preferred. Lab does not expose CORS, so
  this is informational only.
- **Helidon SE (phase 4)**: plain Java, no Jakarta APIs, minimal
  footprint. Routing via `WebServer` builder, DB access via Helidon DB
  Client (Vert.x). Style is imperative-by-default. The new declarative
  APIs in 4.4 are opt-in via code-generation (annotations like
  `@RestServer.Endpoint`, `@Http.Path`, `@Service.Singleton`,
  `@Metrics.Counted`).
- **Helidon MP (phase 3)**: MicroProfile 6.1 compliant. Jakarta JAX-RS +
  CDI + JPA stack, close to Quarkus in shape. Build with Maven, deploy
  the same distroless image, swap the Quarkus extensions for the
  MicroProfile equivalents. Declarative APIs share the same annotation
  set as SE.
- **Helidon JSON**: new build-time JSON library (3x faster than Jackson
  in upstream benchmarks). Optional for the lab. Default to Jackson for
  consistency with the Java baseline. Switching to Helidon JSON is a
  follow-up if performance becomes a concern.
- **Database support**: Oracle Database 26ai added in 4.4. Lab uses
  Postgres exclusively, so no impact.

## Naming and layout reminders

Repository layout for each new stack lives under `services/<stack>-svc/`,
following the per-stack idiom (Maven, Cargo, npm, Python, Go). Each service
ships:

- its source tree
- its own `Dockerfile` (multistage, distroless or chiseled runtime)
- its own `helm/` chart (Deployment + Service + Secret +
  ServiceMonitor) mirroring the pattern in `services/order-service/helm/`
- its own `README.md` with quickstart + endpoint map
- a `scenarios/<stack>-svc-validation.js` k6 composite scenario (one per
  stack, hitting the 12 fault endpoints)
- an entry in `manifests/perf-sentinel-daemon.yaml` and
  `manifests/scaphandre-mock.yaml`
- an entry in `manifests/postgres-multistack-schemas.yaml`'s schema list

Do not introduce a monorepo build tool to "share" code between stacks. Each
service is intentionally autonomous so that one stack's churn never blocks
another.
