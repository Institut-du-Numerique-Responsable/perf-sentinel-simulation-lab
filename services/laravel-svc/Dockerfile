# laravel-svc: Laravel 13 + Eloquent multistack member for perf-sentinel-simulation-lab.
#
# The point of this service is the native OpenTelemetry PHP auto-instrumentation:
# `opentelemetry-auto-laravel` tags the HTTP kernel + Eloquent spans with the
# app-wide InstrumentationScope `io.opentelemetry.contrib.php.laravel`, and
# `opentelemetry-auto-pdo` tags the SQL leaf with `io.opentelemetry.contrib.php.pdo`.
# The daemon walks the leaf-to-root scope chain, sees the laravel scope, and maps
# every finding in the request to suggested_fix.framework = php_laravel_eloquent.
#
# Single-stage (ponytail): the opentelemetry PECL extension must be present at
# runtime, and rebuilding it in a second stage buys only image size, which does
# not matter for a lab member. Build with: docker build -t laravel-svc:s1 services/laravel-svc
FROM php:8.5-cli-trixie

# Build + runtime libs: git/unzip for composer, libpq for pdo_pgsql, PHPIZE deps
# for the opentelemetry PECL extension.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git unzip libpq-dev $PHPIZE_DEPS \
 && docker-php-ext-install -j"$(nproc)" pdo_pgsql sockets \
 && pecl install opentelemetry-1.5.0 \
 && docker-php-ext-enable opentelemetry \
 && apt-get purge -y --auto-remove $PHPIZE_DEPS \
 && rm -rf /var/lib/apt/lists/*

# php.ini tuning (the extension is already enabled by docker-php-ext-enable;
# this only raises limits for the fault endpoints).
COPY docker/php.ini /usr/local/etc/php/conf.d/zz-laravel-svc.ini

# Composer. Disable the advisory-block policy: it refuses every Laravel release
# flagged in the advisory DB, which would fail the resolve. This is a lab
# member validating perf-sentinel, not a shipped app, so ignoring advisories is
# acceptable (ponytail: bypass, not a security regression here).
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
# Advisory-block off (see above) + trust the composer plugins the OTLP exporter
# discovery and OTel auto-instrumentation SPI use, so they are not silently
# skipped under COMPOSER_NO_INTERACTION (mirrors symfony-svc).
RUN composer config --global policy.advisories.block false \
 && composer config --global --no-plugins allow-plugins.php-http/discovery true \
 && composer config --global --no-plugins allow-plugins.tbachert/spi true

WORKDIR /app
# Lay down the Laravel 13 skeleton without resolving dependencies, then replace
# its metadata with the committed dependency graph. The framework selector is
# intentionally still a range, and composer.lock makes the installed graph stable.
RUN composer create-project laravel/laravel:^13.0 /app --no-scripts --prefer-dist --no-install
# shortcut: opentelemetry-auto-laravel is pinned to exactly 1.9.0. 1.9.1+ drops
# db.query.text from the Eloquent getModels span, so perf-sentinel then counts every
# model load twice (laravel query span + PDO::prepare) and redundant-sql flips to
# n_plus_one_sql; 1.10 also splits the scope into io.opentelemetry.contrib.php.laravel.*.
# Upgrade once the daemon collapses those sibling SQL spans.
COPY composer.json composer.lock /app/
RUN composer validate --strict --no-check-all \
 && composer install --no-scripts --prefer-dist

# Overlay our customisations on top of the skeleton (routes, controllers, models,
# bootstrap wiring, config, env) then re-dump the optimised autoloader.
COPY overlay/ /app/
COPY docker/bootstrap-schema.php /app/docker/bootstrap-schema.php
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN composer dump-autoload --optimize \
 && chmod +x /usr/local/bin/entrypoint.sh \
 && useradd -r -u 65532 -d /app nonroot \
 # Laravel writes compiled views / bootstrap cache; route them to /tmp (the only
 # writable mount under readOnlyRootFilesystem). storage/ + bootstrap/cache are
 # symlinked to /tmp subdirs created at container start by the entrypoint.
 && rm -rf /app/storage /app/bootstrap/cache \
 && ln -s /tmp/storage /app/storage \
 && ln -s /tmp/bootstrap-cache /app/bootstrap/cache

EXPOSE 8095
USER 65532:65532
# OTel config MUST be real env vars: the SDK autoloader reads getenv() at
# vendor/autoload time, BEFORE Laravel loads .env, so .env values never reach it.
# The helm deployment overrides endpoint / service name / resource attributes.
ENV HTTP_PORT=8095 \
    PHP_CLI_SERVER_WORKERS=20 \
    OTEL_PHP_AUTOLOAD_ENABLED=true \
    OTEL_SERVICE_NAME=laravel-svc \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=none \
    OTEL_LOGS_EXPORTER=none \
    OTEL_TRACES_SAMPLER=always_on \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
    OTEL_BSP_SCHEDULE_DELAY=30000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
