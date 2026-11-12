package com.perfsim.ktor

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.jackson.jackson
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationStopped
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.response.respond
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.flywaydb.core.Flyway
import org.flywaydb.core.api.migration.BaseJavaMigration
import org.flywaydb.core.api.migration.Context
import java.sql.Connection
import java.time.Instant
import kotlin.math.min

private const val SERVICE = "ktor-svc"
private val channels = listOf("email", "sms", "push", "webhook", "slack", "teams")

fun main() {
    embeddedServer(
        Netty,
        host = environment("HTTP_HOST", "0.0.0.0"),
        port = environmentInt("HTTP_PORT", 8_097),
        module = Application::module,
    ).start(wait = true)
}

fun Application.module(testing: Boolean = false, messagingPublisher: MessagingPublisher? = null) {
    val dataSource = if (testing) null else createDataSource().also(::migrate)
    val httpClient = if (testing) null else HttpClient(CIO) {
        install(HttpTimeout) {
            connectTimeoutMillis = 5_000
            requestTimeoutMillis = 15_000
            socketTimeoutMillis = 15_000
        }
    }
    val publisher = if (testing) {
        requireNotNull(messagingPublisher) { "testing requires a MessagingPublisher" }
    } else {
        messagingPublisher ?: MessagingFaultService(requireNotNull(httpClient))
    }
    if (!testing) {
        monitor.subscribe(ApplicationStopped) {
            httpClient?.close()
            dataSource?.close()
        }
    }

    install(ContentNegotiation) { jackson() }

    suspend fun selfGet(path: String): Int {
        if (testing) return 1
        val response = requireNotNull(httpClient).get(environment("SELF_BASE_URL", "http://localhost:8097") + path)
        response.bodyAsText()
        return if (response.status == HttpStatusCode.OK) 1 else 0
    }

    suspend fun fault(
        antiPattern: String,
        input: Map<String, Any>,
        body: suspend () -> Map<String, Any>,
    ): Map<String, Any> {
        val started = System.nanoTime()
        val details = input + body()
        return mapOf(
            "antiPattern" to antiPattern,
            "service" to SERVICE,
            "durationMs" to (System.nanoTime() - started) / 1_000_000,
            "details" to details,
            "timestamp" to Instant.now().toString(),
        )
    }

    routing {
        post("/api/fault/n-plus-one-sql") {
            val items = call.request.queryParameters.int("items", 15)
            call.respond(fault("n_plus_one_sql", mapOf("items" to items)) {
                if (testing) return@fault mapOf("orders_touched" to items, "items_total" to items * 5)
                val total = withContext(Dispatchers.IO) {
                    requireNotNull(dataSource).connection.use { connection ->
                        (1..items).sumOf { orderId ->
                            val sql = "SELECT count(*) FROM ktor.order_items WHERE order_id = $orderId"
                            connection.createStatement().use { statement ->
                                statement.executeQuery(sql).use { result ->
                                    result.next()
                                    result.getInt(1)
                                }
                            }
                        }
                    }
                }
                mapOf("orders_touched" to items, "items_total" to total)
            })
        }

        post("/api/fault/redundant-sql") {
            val repeats = call.request.queryParameters.int("repeats", 10)
            call.respond(fault("redundant_sql", mapOf("repeats" to repeats)) {
                if (testing) return@fault mapOf("queries_made" to repeats, "rows_seen" to repeats * 4)
                val total = withContext(Dispatchers.IO) {
                    requireNotNull(dataSource).connection.use { connection ->
                        repeatSum(repeats) {
                            connection.createStatement().use { statement ->
                                statement.executeQuery("SELECT count(*) FROM ktor.payments WHERE customer_id = 1").use { result ->
                                    result.next()
                                    result.getInt(1)
                                }
                            }
                        }
                    }
                }
                mapOf("queries_made" to repeats, "rows_seen" to total)
            })
        }

        post("/api/fault/slow-sql") {
            val delayMs = call.request.queryParameters.long("delayMs", 600)
            val repeats = call.request.queryParameters.int("repeats", 6)
            call.respond(fault("slow_sql", mapOf("delayMs" to delayMs, "repeats" to repeats)) {
                if (!testing) withContext(Dispatchers.IO) {
                    requireNotNull(dataSource).connection.use { connection ->
                        repeat(repeats) { index ->
                            connection.createStatement().use { statement ->
                                statement.executeQuery(
                                    "SELECT pg_sleep(${delayMs / 1000.0}), * FROM ktor.orders ORDER BY id OFFSET $index LIMIT 1",
                                ).use { result -> while (result.next()) { /* drain */ } }
                            }
                        }
                    }
                }
                mapOf("queries_executed" to repeats, "delay_ms" to delayMs)
            })
        }

        post("/api/fault/pool-saturation") {
            val concurrency = call.request.queryParameters.int("concurrency", 20)
            call.respond(fault("pool_saturation", mapOf("concurrency" to concurrency)) {
                if (!testing) coroutineScope {
                    (0 until concurrency).map {
                        async(Dispatchers.IO) {
                            requireNotNull(dataSource).connection.use { connection ->
                                connection.prepareStatement("SELECT pg_sleep(0.4)").use { it.execute() }
                            }
                        }
                    }.awaitAll()
                }
                mapOf("tasks_launched" to concurrency, "tasks_completed" to concurrency)
            })
        }

        post("/api/fault/n-plus-one-http") {
            val recipients = call.request.queryParameters.int("recipients", 10)
            call.respond(fault("n_plus_one_http", mapOf("recipients" to recipients)) {
                val ok = (0 until recipients).sumOf { selfGet("/api/external/mock?delayMs=0&seq=$it&op=0") }
                mapOf("calls_made" to recipients, "calls_ok" to ok)
            })
        }

        post("/api/fault/redundant-http") {
            val repeats = call.request.queryParameters.int("repeats", 10)
            call.respond(fault("redundant_http", mapOf("repeats" to repeats)) {
                val ok = (0 until repeats).sumOf { selfGet("/api/payments/history?customerId=1&limit=10") }
                mapOf("calls_made" to repeats, "calls_ok" to ok)
            })
        }

        post("/api/fault/slow-http") {
            val delayMs = call.request.queryParameters.long("delayMs", 600)
            val repeats = call.request.queryParameters.int("repeats", 6)
            call.respond(fault("slow_http", mapOf("delayMs" to delayMs, "repeats" to repeats)) {
                val ok = (0 until repeats).sumOf { selfGet("/api/external/mock?delayMs=$delayMs&seq=$it&op=0") }
                mapOf("calls_made" to repeats, "calls_ok" to ok, "delay_ms" to delayMs)
            })
        }

        post("/api/fault/fanout") {
            val width = call.request.queryParameters.int("width", 40)
            call.respond(fault("excessive_fanout", mapOf("width" to width)) {
                val ok = coroutineScope {
                    (0 until width).map { index ->
                        async { selfGet("/api/external/mock?delayMs=10&seq=$index&op=0") }
                    }.awaitAll().sum()
                }
                mapOf("children_launched" to width, "children_ok" to ok)
            })
        }

        post("/api/fault/chatty") {
            val calls = call.request.queryParameters.int("calls", 30)
            call.respond(fault("chatty_service", mapOf("calls" to calls)) {
                val ok = (0 until calls).sumOf { selfGet("/api/external/mock?delayMs=5&seq=$it&op=${it % 7}") }
                mapOf("calls_made" to calls, "calls_ok" to ok)
            })
        }

        post("/api/fault/serialized") {
            val steps = call.request.queryParameters.int("steps", 6)
            call.respond(fault("serialized_calls", mapOf("steps" to steps)) {
                val started = System.nanoTime()
                val ok = (0 until min(steps, channels.size)).sumOf {
                    selfGet("/api/dispatch/${channels[it]}?delayMs=80")
                }
                mapOf("steps_ok" to ok, "wall_clock_ms" to (System.nanoTime() - started) / 1_000_000)
            })
        }

        post("/api/fault/n-plus-one-messaging") {
            val parameters = call.request.queryParameters
            val messages = parameters.optionalInt("messages", 8)
            val broker = parameters["broker"] ?: "rabbitmq"
            if (messages == null || broker != "rabbitmq" || messages !in 5..100) {
                call.respond(HttpStatusCode.BadRequest, mapOf("error" to "invalid messaging request"))
                return@post
            }
            call.respond(fault("n_plus_one_messaging", mapOf("messages" to messages, "broker" to broker)) {
                publisher.publishSequentially(messages)
            })
        }

        post("/api/fault/slow-messaging") {
            val parameters = call.request.queryParameters
            val delayMs = parameters.optionalLong("delayMs", 600)
            val repeats = parameters.optionalInt("repeats", 3)
            val broker = parameters["broker"] ?: "rabbitmq"
            if (delayMs == null || repeats == null || broker != "rabbitmq" || delayMs !in 501..5_000 || repeats !in 3..20) {
                call.respond(HttpStatusCode.BadRequest, mapOf("error" to "invalid messaging request"))
                return@post
            }
            call.respond(fault("slow_messaging", mapOf("delayMs" to delayMs, "repeats" to repeats, "broker" to broker)) {
                publisher.publishSlowly(delayMs, repeats)
            })
        }

        get("/api/external/mock") {
            val delayMs = call.request.queryParameters.long("delayMs", 0)
            if (!testing) delay(delayMs)
            call.respond(
                mapOf(
                    "ok" to true,
                    "seq" to call.request.queryParameters.int("seq", 0),
                    "op" to call.request.queryParameters.int("op", 0),
                    "delayMs" to delayMs,
                ),
            )
        }

        get("/api/dispatch/{channel}") {
            val channel = call.parameters["channel"].orEmpty()
            if (channel !in channels) {
                call.respond(HttpStatusCode.NotFound, mapOf("error" to "unknown channel"))
                return@get
            }
            val delayMs = call.request.queryParameters.long("delayMs", 0)
            if (!testing) delay(delayMs)
            call.respond(mapOf("channel" to channel, "dispatched" to true, "delayMs" to delayMs))
        }

        get("/api/payments/history") {
            val customerId = call.request.queryParameters.long("customerId", 1)
            val limit = call.request.queryParameters.int("limit", 10).coerceIn(1, 100)
            if (testing) {
                call.respond(emptyList<List<Any>>())
                return@get
            }
            val rows = withContext(Dispatchers.IO) {
                requireNotNull(dataSource).connection.use { connection ->
                    connection.prepareStatement(
                        "SELECT id, order_id, customer_id, amount_cents, status FROM ktor.payments WHERE customer_id = ? ORDER BY id LIMIT ?",
                    ).use { statement ->
                        statement.setLong(1, customerId)
                        statement.setInt(2, limit)
                        statement.executeQuery().use { result ->
                            buildList {
                                while (result.next()) add(
                                    listOf(
                                        result.getLong("id"),
                                        result.getLong("order_id"),
                                        result.getLong("customer_id"),
                                        result.getLong("amount_cents"),
                                        result.getString("status"),
                                    ),
                                )
                            }
                        }
                    }
                }
            }
            call.respond(rows)
        }

        get("/health/live") { call.respond(mapOf("status" to "UP")) }
        get("/health/ready") {
            val ready = testing || withContext(Dispatchers.IO) {
                runCatching {
                    requireNotNull(dataSource).connection.use { connection ->
                        connection.createStatement().use { it.execute("SELECT 1") }
                    }
                }.isSuccess
            }
            call.respond(
                if (ready) HttpStatusCode.OK else HttpStatusCode.ServiceUnavailable,
                mapOf("status" to if (ready) "UP" else "DOWN"),
            )
        }
    }
}

private fun createDataSource(): HikariDataSource = HikariDataSource(HikariConfig().apply {
    jdbcUrl = environment("DB_URL", "jdbc:postgresql://postgres.db.svc.cluster.local:5432/lab?currentSchema=ktor")
    username = requiredEnvironment("DB_USER")
    password = requiredEnvironment("DB_PASSWORD")
    maximumPoolSize = 10
    minimumIdle = 1
    schema = "ktor"
})

private fun migrate(dataSource: HikariDataSource) {
    Flyway.configure()
        .dataSource(dataSource)
        .schemas("ktor")
        .defaultSchema("ktor")
        .createSchemas(false)
        .javaMigrations(V1__init())
        .load()
        .migrate()
}

private class V1__init : BaseJavaMigration() {
    override fun migrate(context: Context) {
        context.connection.createStatement().use { statement ->
            statement.execute(
                """
                CREATE TABLE IF NOT EXISTS ktor.orders (
                    id BIGINT PRIMARY KEY, customer VARCHAR(255) NOT NULL, status VARCHAR(32) NOT NULL,
                    total_cents BIGINT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                );
                CREATE TABLE IF NOT EXISTS ktor.order_items (
                    id BIGINT PRIMARY KEY, order_id BIGINT NOT NULL REFERENCES ktor.orders(id) ON DELETE CASCADE,
                    sku VARCHAR(64) NOT NULL, quantity INTEGER NOT NULL, price_cents BIGINT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS ktor.payments (
                    id BIGINT PRIMARY KEY, order_id BIGINT NOT NULL, customer_id BIGINT NOT NULL,
                    amount_cents BIGINT NOT NULL, status VARCHAR(32) NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                );
                CREATE INDEX IF NOT EXISTS idx_ktor_order_items_order_id ON ktor.order_items(order_id);
                CREATE INDEX IF NOT EXISTS idx_ktor_payments_customer_id ON ktor.payments(customer_id);
                INSERT INTO ktor.orders (id, customer, status, total_cents)
                    SELECT g, 'customer-' || g, 'PENDING', g * 1000 FROM generate_series(1, 100) g
                    ON CONFLICT (id) DO NOTHING;
                INSERT INTO ktor.order_items (id, order_id, sku, quantity, price_cents)
                    SELECT (o.id - 1) * 5 + g, o.id, 'SKU-' || (o.id * 10 + g), 1 + (g % 5), 100 + g * 50
                    FROM ktor.orders o CROSS JOIN generate_series(1, 5) g WHERE o.id <= 100
                    ON CONFLICT (id) DO NOTHING;
                INSERT INTO ktor.payments (id, order_id, customer_id, amount_cents, status)
                    SELECT g, ((g - 1) % 100) + 1, ((g - 1) % 50) + 1, g * 100, 'AUTHORIZED'
                    FROM generate_series(1, 200) g ON CONFLICT (id) DO NOTHING;
                """.trimIndent(),
            )
        }
    }
}

private inline fun repeatSum(times: Int, body: () -> Int): Int {
    var total = 0
    repeat(times) { total += body() }
    return total
}

private fun io.ktor.http.Parameters.int(name: String, default: Int): Int = this[name]?.toIntOrNull() ?: default
private fun io.ktor.http.Parameters.long(name: String, default: Long): Long = this[name]?.toLongOrNull() ?: default
private fun io.ktor.http.Parameters.optionalInt(name: String, default: Int): Int? =
    this[name]?.toIntOrNull() ?: if (this[name] == null) default else null
private fun io.ktor.http.Parameters.optionalLong(name: String, default: Long): Long? =
    this[name]?.toLongOrNull() ?: if (this[name] == null) default else null

private fun environment(name: String, fallback: String): String =
    System.getenv(name)?.takeIf(String::isNotBlank) ?: fallback

private fun environmentInt(name: String, fallback: Int): Int =
    System.getenv(name)?.takeIf(String::isNotBlank)?.toInt() ?: fallback

private fun requiredEnvironment(name: String): String =
    requireNotNull(System.getenv(name)?.takeIf(String::isNotBlank)) { "$name is required" }
