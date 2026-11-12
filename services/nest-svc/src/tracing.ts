// Must be imported BEFORE any NestJS or Prisma import. Sets up the
// global OTel NodeSDK with HTTP + Prisma instrumentations. Spans from
// @opentelemetry/instrumentation-http cover both server-side (Express)
// and client-side (axios via Node http module), perf-sentinel sees
// SERVER and CLIENT spans. @prisma/instrumentation adds the `prisma`
// tracer scope on every Prisma query, which is the ORM marker the
// strict classifier consumes.
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { PgInstrumentation } from '@opentelemetry/instrumentation-pg';
import { PrismaInstrumentation } from '@prisma/instrumentation';

// Prisma 6's query engine deferred span emission by a few seconds. The
// default BatchSpanProcessor scheduledDelayMillis (5000 ms) stacks
// on top of that, pushing total latency past the lab's 15 s
// validation flush window. Lowering to 1000 ms keeps the spans
// arriving within the window without measurable overhead (the batch
// still amortises per-span export cost).
const exporter = new OTLPTraceExporter();
const sdk = new NodeSDK({
  spanProcessors: [new BatchSpanProcessor({ exporter, scheduledDelayMillis: 1000 })],
  instrumentations: [
    new HttpInstrumentation(),
    // PgInstrumentation instruments raw `pg` Pool queries (used by
    // the pool-saturation endpoint which bypasses Prisma to get true
    // concurrent connections). Without this, the pg Pool queries are
    // invisible to the daemon's pool_saturation detector. Prisma 7 runs
    // on node-pg too, so each prisma:client:db_query also gets a
    // pg.query child: the daemon does not count it twice (same
    // events_processed and findings as Prisma 6).
    new PgInstrumentation(),
    new PrismaInstrumentation(),
  ],
});

sdk.start();

// Flush pending spans on SIGTERM but do NOT call process.exit.
// NestJS enableShutdownHooks handles the lifecycle (onModuleDestroy
// on PgPoolService + PrismaService) and drains in-flight requests
// before exiting. Calling process.exit here would race with NestJS
// and leak connections.
process.on('SIGTERM', () => {
  sdk.shutdown().catch(() => {});
});
