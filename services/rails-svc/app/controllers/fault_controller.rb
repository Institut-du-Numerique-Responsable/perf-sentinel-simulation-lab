require "pg"

class FaultController < ApplicationController
  class_attribute :messaging_service_factory, default: -> { MessagingFaultService.new }

  # === SQL faults (through ActiveRecord -> ActiveRecord scope) =============

  # N distinct ActiveRecord record loads, one per order id -> n_plus_one_sql.
  # This is THE endpoint the validation keys on. Loading records (not `.count`)
  # routes through ActiveRecord's `_query_by_sql`, which the OTel ActiveRecord
  # instrumentation wraps in a span under
  # `OpenTelemetry::Instrumentation::ActiveRecord`, the ORM marker the daemon
  # maps to suggested_fix.framework = ruby_active_record. (`.count` would only
  # produce an adapter-level PG span and miss the ActiveRecord scope.)
  def n_plus_one_sql
    items = int_param(:items, 15)
    start = monotonic
    total = 0
    (1..items).each { |order_id| total += OrderItem.where(order_id: order_id).to_a.size }
    envelope("n_plus_one_sql", start, { items: items, orders_touched: items, items_total: total })
  end

  # The same ActiveRecord record load repeated with identical params ->
  # redundant_sql (also under the ActiveRecord scope).
  def redundant_sql
    repeats = int_param(:repeats, 10)
    start = monotonic
    total = 0
    # uncached: the per-request query cache would answer the repeats without a round trip.
    # Literal condition: a bound `$1` hides that the params repeat, so strict mode reads it as N+1.
    Payment.uncached { repeats.times { total += Payment.where("customer_id = 1").to_a.size } }
    envelope("redundant_sql", start, { repeats: repeats, queries_made: repeats, rows_seen: total })
  end

  # find_by_sql also routes through `_query_by_sql` (ActiveRecord scope); a
  # leading pg_sleep makes each query slow -> slow_sql.
  def slow_sql
    delay_ms = int_param(:delayMs, 600)
    repeats = int_param(:repeats, 6)
    seconds = delay_ms / 1000.0
    start = monotonic
    executed = 0
    repeats.times do |i|
      Order.find_by_sql("SELECT pg_sleep(#{seconds}), orders.* FROM orders ORDER BY id OFFSET #{i} LIMIT 1")
      executed += 1
    end
    envelope("slow_sql", start, { delayMs: delay_ms, repeats: repeats, queries_executed: executed })
  end

  # pool-saturation deliberately bypasses ActiveRecord's connection pool and
  # opens independent raw `pg` connections (instrumented under the PG scope),
  # so the daemon sees genuinely overlapping SQL spans. OTel context is carried
  # into each worker thread so the CLIENT spans parent onto the request span.
  def pool_saturation
    concurrency = int_param(:concurrency, 20)
    start = monotonic
    ctx = OpenTelemetry::Context.current
    threads = Array.new(concurrency) do
      Thread.new { OpenTelemetry::Context.with_current(ctx) { raw_pg_sleep(0.4) } }
    end
    completed = threads.sum(&:value)
    envelope("pool_saturation", start,
             { concurrency: concurrency, tasks_launched: concurrency, tasks_completed: completed })
  end

  # === HTTP faults (through Net::HTTP -> Net::HTTP scope) ==================

  def n_plus_one_http
    recipients = int_param(:recipients, 10)
    start = monotonic
    ok = (0...recipients).sum { |i| http_get("/api/external/mock?delayMs=0&seq=#{i}&op=0") }
    envelope("n_plus_one_http", start, { recipients: recipients, calls_made: recipients, calls_ok: ok })
  end

  def redundant_http
    repeats = int_param(:repeats, 10)
    start = monotonic
    ok = (0...repeats).sum { http_get("/api/payments/history?customerId=1&limit=10") }
    envelope("redundant_http", start, { repeats: repeats, calls_made: repeats, calls_ok: ok })
  end

  def slow_http
    delay_ms = int_param(:delayMs, 600)
    repeats = int_param(:repeats, 6)
    start = monotonic
    ok = (0...repeats).sum { |i| http_get("/api/external/mock?delayMs=#{delay_ms}&seq=#{i}&op=0") }
    envelope("slow_http", start, { delayMs: delay_ms, repeats: repeats, calls_made: repeats, calls_ok: ok })
  end

  # Many concurrent children off ONE request -> excessive_fanout. Context is
  # propagated into the threads so the CLIENT spans share the request trace.
  def fanout
    width = int_param(:width, 40)
    start = monotonic
    ctx = OpenTelemetry::Context.current
    threads = (0...width).map do |i|
      Thread.new do
        OpenTelemetry::Context.with_current(ctx) { http_get("/api/external/mock?delayMs=10&seq=#{i}&op=0") }
      end
    end
    ok = threads.sum(&:value)
    envelope("excessive_fanout", start, { width: width, children_launched: width, children_ok: ok })
  end

  def chatty
    calls = int_param(:calls, 30)
    start = monotonic
    ok = (0...calls).sum { |i| http_get("/api/external/mock?delayMs=5&seq=#{i}&op=#{i % 7}") }
    envelope("chatty_service", start, { calls: calls, calls_made: calls, calls_ok: ok })
  end

  def serialized
    steps = [int_param(:steps, 6), CHANNELS.length].min
    start = monotonic
    ok = (0...steps).sum { |i| http_get("/api/dispatch/#{CHANNELS[i]}?delayMs=80") }
    envelope("serialized_calls", start, { steps: steps, steps_ok: ok })
  end

  def n_plus_one_messaging
    messages = messaging_int_param(:messages, 8)
    if params.fetch(:broker, "rabbitmq") != "rabbitmq" || messages.nil? || !messages.between?(5, 100)
      return render json: { error: "invalid messaging parameters" }, status: :bad_request
    end

    start = monotonic
    details = self.class.messaging_service_factory.call.publish_sequentially(messages)
    envelope("n_plus_one_messaging", start, details)
  end

  def slow_messaging
    delay_ms = messaging_int_param(:delayMs, 600)
    repeats = messaging_int_param(:repeats, 3)
    if params.fetch(:broker, "rabbitmq") != "rabbitmq" || delay_ms.nil? || repeats.nil? ||
       !delay_ms.between?(501, 5000) || !repeats.between?(3, 20)
      return render json: { error: "invalid messaging parameters" }, status: :bad_request
    end

    start = monotonic
    details = self.class.messaging_service_factory.call.publish_slowly(delay_ms, repeats)
    envelope("slow_messaging", start, details)
  end

  private

  def messaging_int_param(key, default)
    return default unless params.key?(key)

    value = params[key]
    return unless value.is_a?(String) && /\A[0-9]+\z/.match?(value)

    Integer(value, 10)
  end

  def raw_pg_sleep(seconds)
    conn = nil
    conn = PG.connect(
      host: ENV.fetch("DB_HOST", "localhost"),
      port: ENV.fetch("DB_PORT", "5432"),
      dbname: ENV.fetch("DB_NAME", "lab"),
      user: ENV.fetch("DB_USER", "rails_user"),
      password: ENV.fetch("DB_PASSWORD", "lab_rails"),
      options: "-csearch_path=rails,public",
    )
    conn.exec("SELECT pg_sleep(#{seconds})")
    1
  rescue StandardError
    0
  ensure
    # Close the raw libpq connection on every path: pool-saturation opens 20
    # of these concurrently outside the AR pool, so a swallowed error must not
    # leak a Postgres backend against the shared max_connections.
    conn&.close
  end
end
