import {
  BadRequestException,
  CallHandler,
  Controller,
  ExecutionContext,
  Injectable,
  InternalServerErrorException,
  NestInterceptor,
  Post,
  Query,
  UseInterceptors,
} from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { SpanKind, SpanStatusCode, trace } from '@opentelemetry/api';
import { PrismaService } from '../prisma/prisma.service';
import { PgPoolService } from '../prisma/pg-pool.service';
import { MessagingService } from './messaging.service';
import { firstValueFrom } from 'rxjs';

const SERVICE = 'nest-svc';
const CHANNELS = ['email', 'sms', 'push', 'webhook', 'slack', 'teams'];

function envelope(antiPattern: string, start: number, details: Record<string, unknown>) {
  return {
    antiPattern,
    service: SERVICE,
    durationMs: Date.now() - start,
    details,
    timestamp: new Date().toISOString(),
  };
}

function boundedInteger(value: unknown, fallback: number, minimum: number, maximum: number): number {
  if (value === undefined) return fallback;
  if (typeof value !== 'string' || !/^\d+$/.test(value)) throw new BadRequestException();
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new BadRequestException();
  }
  return parsed;
}

function rabbitMqBroker(value: unknown): void {
  if (value !== 'rabbitmq') throw new BadRequestException();
}

@Injectable()
export class FaultRouteInterceptor implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler) {
    const http = context.switchToHttp();
    const request = http.getRequest<{
      baseUrl?: unknown;
      route?: { path?: unknown };
    }>();
    http.getResponse<{ status(code: number): unknown }>().status(200);
    const baseUrl = request.baseUrl;
    const routePath = request.route?.path;
    if (typeof baseUrl === 'string' && typeof routePath === 'string') {
      trace.getActiveSpan()?.setAttribute('http.route', `${baseUrl}${routePath}`);
    }
    return next.handle();
  }
}

@Controller('api/fault')
@UseInterceptors(FaultRouteInterceptor)
export class FaultController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly pgPool: PgPoolService,
    private readonly http: HttpService,
    private readonly messaging: MessagingService,
  ) {}

  // === SQL anti-patterns =====================================================

  @Post('n-plus-one-sql')
  async nPlusOneSql(@Query('items') items = '15') {
    const n = parseInt(items, 10) || 15;
    const start = Date.now();
    let total = 0;
    for (let orderId = 1; orderId <= n; orderId++) {
      const count = await this.prisma.orderItem.count({
        where: { orderId: BigInt(orderId) },
      });
      total += count;
    }
    return envelope('n_plus_one_sql', start, {
      items: n, orders_touched: n, items_total: total,
    });
  }

  @Post('redundant-sql')
  async redundantSql(@Query('repeats') repeats = '10') {
    const n = parseInt(repeats, 10) || 10;
    const start = Date.now();
    let total = 0;
    for (let i = 0; i < n; i++) {
      const count = await trace.getTracer(FaultController.name).startActiveSpan(
        'SELECT nest.payments',
        {
          kind: SpanKind.CLIENT,
          attributes: {
            'db.system': 'postgresql',
            'db.statement': 'SELECT count(*) FROM nest.payments WHERE customer_id = 1',
            'db.operation': 'SELECT',
          },
        },
        async (span) => {
          try {
            return await this.prisma.payment.count({ where: { customerId: 1n } });
          } catch (error) {
            const exception = error instanceof Error ? error : new Error(String(error));
            span.recordException(exception);
            span.setStatus({ code: SpanStatusCode.ERROR, message: exception.message });
            throw exception;
          } finally {
            span.end();
          }
        },
      );
      total += count;
    }
    return envelope('redundant_sql', start, {
      repeats: n, queries_made: n, rows_seen: total,
    });
  }

  @Post('slow-sql')
  async slowSql(
    @Query('delayMs') delayMs = '600',
    @Query('repeats') repeats = '6',
  ) {
    const ms = parseInt(delayMs, 10) || 600;
    const n = parseInt(repeats, 10) || 6;
    const seconds = ms / 1000;
    const start = Date.now();
    let executed = 0;
    for (let i = 0; i < n; i++) {
      await this.prisma.$executeRawUnsafe(
        `SELECT pg_sleep(${seconds}), * FROM nest.orders ORDER BY id OFFSET ${i} LIMIT 1`,
      );
      executed++;
    }
    return envelope('slow_sql', start, {
      delayMs: ms, repeats: n, queries_executed: executed, delay_ms: ms,
    });
  }

  // Bypasses Prisma for pool-saturation: the dedicated raw pg Pool
  // (max 10) takes 20 truly concurrent queries, so the daemon sees N
  // overlapping SQL spans within a tight window: the shape its
  // pool_saturation detector requires.
  @Post('pool-saturation')
  async poolSaturation(@Query('concurrency') concurrency = '20') {
    const n = parseInt(concurrency, 10) || 20;
    const start = Date.now();
    const tasks = Array.from({ length: n }, async () => {
      const client = await this.pgPool.pool.connect();
      try {
        await client.query('SELECT pg_sleep(0.4)');
        return 1;
      } catch {
        return 0;
      } finally {
        client.release();
      }
    });
    const results = await Promise.all(tasks);
    const completed = results.reduce<number>((a, b) => a + b, 0);
    return envelope('pool_saturation', start, {
      concurrency: n, tasks_launched: n, tasks_completed: completed,
    });
  }

  // === HTTP anti-patterns ====================================================

  private async doGet(path: string): Promise<number> {
    try {
      const r = await firstValueFrom(this.http.get(path));
      return r.status === 200 ? 1 : 0;
    } catch {
      return 0;
    }
  }

  @Post('n-plus-one-http')
  async nPlusOneHttp(@Query('recipients') recipients = '10') {
    const n = parseInt(recipients, 10) || 10;
    const start = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet(`/api/external/mock?delayMs=0&seq=${i}&op=0`);
    }
    return envelope('n_plus_one_http', start, {
      recipients: n, calls_made: n, calls_ok: ok,
    });
  }

  @Post('redundant-http')
  async redundantHttp(@Query('repeats') repeats = '10') {
    const n = parseInt(repeats, 10) || 10;
    const start = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet('/api/payments/history?customerId=1&limit=10');
    }
    return envelope('redundant_http', start, {
      repeats: n, calls_made: n, calls_ok: ok,
    });
  }

  @Post('slow-http')
  async slowHttp(
    @Query('delayMs') delayMs = '600',
    @Query('repeats') repeats = '6',
  ) {
    const ms = parseInt(delayMs, 10) || 600;
    const n = parseInt(repeats, 10) || 6;
    const start = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet(`/api/external/mock?delayMs=${ms}&seq=${i}&op=0`);
    }
    return envelope('slow_http', start, {
      delayMs: ms, repeats: n, calls_made: n, calls_ok: ok, delay_ms: ms,
    });
  }

  @Post('fanout')
  async fanout(@Query('width') width = '40') {
    const n = parseInt(width, 10) || 40;
    const start = Date.now();
    const tasks = Array.from({ length: n }, (_, i) =>
      this.doGet(`/api/external/mock?delayMs=10&seq=${i}&op=0`),
    );
    const results = await Promise.all(tasks);
    const ok = results.reduce((a, b) => a + b, 0);
    return envelope('excessive_fanout', start, {
      width: n, children_launched: n, children_ok: ok,
    });
  }

  @Post('chatty')
  async chatty(@Query('calls') calls = '30') {
    const n = parseInt(calls, 10) || 30;
    const start = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet(`/api/external/mock?delayMs=5&seq=${i}&op=${i % 7}`);
    }
    return envelope('chatty_service', start, {
      calls: n, calls_made: n, calls_ok: ok,
    });
  }

  @Post('serialized')
  async serialized(@Query('steps') steps = '6') {
    const n = Math.min(parseInt(steps, 10) || 6, CHANNELS.length);
    const start = Date.now();
    const wcStart = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet(`/api/dispatch/${CHANNELS[i]}?delayMs=80`);
    }
    const wallClockMs = Date.now() - wcStart;
    return envelope('serialized_calls', start, {
      steps: n, steps_ok: ok, wall_clock_ms: wallClockMs,
    });
  }

  // === Messaging anti-patterns =============================================

  @Post('n-plus-one-messaging')
  async nPlusOneMessaging(
    @Query('messages') messages: unknown,
    @Query('broker') broker: unknown,
  ) {
    const count = boundedInteger(messages, 8, 5, 100);
    rabbitMqBroker(broker);
    const start = Date.now();
    try {
      const details = await this.messaging.publishSequentially(count);
      return envelope('n_plus_one_messaging', start, details);
    } catch {
      throw new InternalServerErrorException('RabbitMQ operation failed');
    }
  }

  @Post('slow-messaging')
  async slowMessaging(
    @Query('delayMs') delayMs: unknown,
    @Query('repeats') repeats: unknown,
    @Query('broker') broker: unknown,
  ) {
    const delay = boundedInteger(delayMs, 600, 501, 5_000);
    const count = boundedInteger(repeats, 3, 3, 20);
    rabbitMqBroker(broker);
    const start = Date.now();
    try {
      const details = await this.messaging.publishSlowly(delay, count);
      return envelope('slow_messaging', start, details);
    } catch {
      throw new InternalServerErrorException('RabbitMQ operation failed');
    }
  }
}
