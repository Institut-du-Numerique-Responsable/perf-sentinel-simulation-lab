import { Injectable, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from '../generated/prisma/client';

// Prisma 7 talks to PostgreSQL through node-pg. The Prisma-only
// `?schema=` param moves to the adapter option so generated SQL stays
// qualified as "nest"."<table>", like the Prisma 6 engine emitted.
function adapter(): PrismaPg {
  const url = process.env.DATABASE_URL || '';
  const schema = URL.canParse(url) ? new URL(url).searchParams.get('schema') : null;
  return new PrismaPg(
    { connectionString: url.replace(/[?&]schema=[^&]*/g, '') || undefined },
    schema ? { schema } : undefined,
  );
}

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(PrismaService.name);

  constructor() {
    super({ adapter: adapter() });
  }

  async onModuleInit() {
    await this.$connect();
    await this.ensureSchema();
  }

  async onModuleDestroy() {
    await this.$disconnect();
  }

  private async ensureSchema() {
    // Prisma runs each raw call as one prepared statement, which does
    // not accept multiple commands. Split each DDL statement.
    await this.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS nest.orders (
        id BIGSERIAL PRIMARY KEY, customer VARCHAR(255) NOT NULL,
        status VARCHAR(32) NOT NULL DEFAULT 'PENDING',
        total_cents BIGINT NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    await this.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS nest.order_items (
        id BIGSERIAL PRIMARY KEY,
        order_id BIGINT NOT NULL REFERENCES nest.orders(id) ON DELETE CASCADE,
        sku VARCHAR(64) NOT NULL, quantity INTEGER NOT NULL,
        price_cents BIGINT NOT NULL)`);
    await this.$executeRawUnsafe(`CREATE TABLE IF NOT EXISTS nest.payments (
        id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL,
        customer_id BIGINT NOT NULL, amount_cents BIGINT NOT NULL DEFAULT 0,
        status VARCHAR(32) NOT NULL DEFAULT 'AUTHORIZED',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    await this.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS idx_nest_order_items_order_id ON nest.order_items(order_id)`);
    await this.$executeRawUnsafe(`CREATE INDEX IF NOT EXISTS idx_nest_payments_customer_id ON nest.payments(customer_id)`);

    const probe: { exists: boolean }[] = await this.$queryRaw`
      SELECT EXISTS(SELECT 1 FROM nest.orders LIMIT 1) AS exists`;
    if (probe[0]?.exists) {
      this.logger.log('Schema already seeded');
      return;
    }

    await this.$executeRawUnsafe(`
      INSERT INTO nest.orders (customer, status, total_cents)
      SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
      FROM generate_series(1, 100) AS g ON CONFLICT DO NOTHING`);
    await this.$executeRawUnsafe(`
      INSERT INTO nest.order_items (order_id, sku, quantity, price_cents)
      SELECT o.id, 'SKU-' || (o.id * 10 + g), (1 + (g % 5)), (100 + g * 50)::bigint
      FROM nest.orders o CROSS JOIN generate_series(1, 5) AS g WHERE o.id <= 100`);
    await this.$executeRawUnsafe(`
      INSERT INTO nest.payments (order_id, customer_id, amount_cents, status)
      SELECT ((g-1) % 100)+1, ((g-1) % 50)+1, (g * 100)::bigint, 'AUTHORIZED'
      FROM generate_series(1, 200) AS g`);
    this.logger.log('Schema seeded');
  }
}
