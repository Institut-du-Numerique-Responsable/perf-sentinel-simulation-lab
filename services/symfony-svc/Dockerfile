# symfony-svc: Symfony 7 + Doctrine ORM multistack member for perf-sentinel-simulation-lab.
#
# Native OpenTelemetry PHP auto-instrumentation:
#   opentelemetry-auto-symfony  -> app-wide SERVER scope io.opentelemetry.contrib.php.symfony
#   opentelemetry-auto-doctrine -> DB-specific scope   io.opentelemetry.contrib.php.doctrine
#   opentelemetry-auto-pdo      -> SQL leaf scope       io.opentelemetry.contrib.php.pdo
# The daemon walks the leaf-to-root scope chain: SQL findings match the vendor
# php.doctrine rule -> suggested_fix.framework = php_doctrine; non-SQL findings
# have only the php.symfony scope, which is not a vendor rule, so they fall through
# to the php.* prefix -> php_generic. That asymmetry is the point of this service.
#
# Single-stage (ponytail): the opentelemetry PECL extension must be present at
# runtime. Build with: docker build -t symfony-svc:s1 services/symfony-svc
FROM php:8.5-cli-trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git unzip libpq-dev $PHPIZE_DEPS \
 && docker-php-ext-install -j"$(nproc)" pdo_pgsql sockets \
 && pecl install opentelemetry-1.5.0 \
 && docker-php-ext-enable opentelemetry \
 && apt-get purge -y --auto-remove $PHPIZE_DEPS \
 && rm -rf /var/lib/apt/lists/*

COPY docker/php.ini /usr/local/etc/php/conf.d/zz-symfony-svc.ini

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
# Advisory-block off (lab image, see laravel-svc) + trust the composer plugins the
# Symfony skeleton + OTLP discovery use.
RUN composer config --global policy.advisories.block false \
 && composer config --global --no-plugins allow-plugins.symfony/flex true \
 && composer config --global --no-plugins allow-plugins.symfony/runtime true \
 && composer config --global --no-plugins allow-plugins.php-http/discovery true \
 && composer config --global --no-plugins allow-plugins.tbachert/spi true

WORKDIR /app
# Lay down the ranged Symfony skeleton so Flex creates its boot files, then use
# the committed application dependency graph. --no-check-all suppresses only
# Composer's warning about the plan-required exact php-amqplib version.
RUN composer create-project symfony/skeleton:^7.1 /app --no-scripts --prefer-dist
COPY composer.json composer.lock /app/
RUN composer validate --strict --no-check-all \
 && composer install --no-scripts --prefer-dist

COPY overlay/ /app/
COPY docker/bootstrap-schema.php /app/docker/bootstrap-schema.php
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN composer dump-autoload --optimize \
 && chmod +x /usr/local/bin/entrypoint.sh \
 && useradd -r -u 65532 -d /app nonroot \
 # Symfony writes the compiled container + logs to var/; route it to /tmp (the
 # only writable mount under readOnlyRootFilesystem).
 && rm -rf /app/var \
 && ln -s /tmp/var /app/var

EXPOSE 8096
USER 65532:65532
ENV HTTP_PORT=8096 \
    PHP_CLI_SERVER_WORKERS=20 \
    APP_ENV=prod \
    OTEL_PHP_AUTOLOAD_ENABLED=true \
    OTEL_SERVICE_NAME=symfony-svc \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=none \
    OTEL_LOGS_EXPORTER=none \
    OTEL_TRACES_SAMPLER=always_on \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
    OTEL_BSP_SCHEDULE_DELAY=30000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
