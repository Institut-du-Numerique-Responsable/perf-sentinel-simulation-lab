# Configure OpenTelemetry once, during Rails initialize!, BEFORE the schema
# bootstrap or any request runs, so ActiveRecord is patched and every query
# carries the `OpenTelemetry::Instrumentation::ActiveRecord` scope.
#
# Exporter target, protocol, sampler and resource attributes all come from the
# OTEL_* env vars the helm deployment injects (OTEL_EXPORTER_OTLP_ENDPOINT,
# OTEL_EXPORTER_OTLP_PROTOCOL, OTEL_RESOURCE_ATTRIBUTES, OTEL_TRACES_SAMPLER).
# A short batch schedule delay lands spans inside the lab's ~15s validation
# flush window (mirrors django-svc's 1000ms).
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/rails"
require "opentelemetry/instrumentation/pg"

ENV["OTEL_BSP_SCHEDULE_DELAY"] ||= "1000"

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "rails-svc")
  # use_all is required: `c.use "OpenTelemetry::Instrumentation::Rails"` alone
  # is a no-op umbrella (its install block is `install { true }`) and silently
  # skips Rack/ActionPack/ActiveRecord: no SERVER span, every DB/HTTP span
  # becomes its own single-span trace, and all multi-span structural findings
  # vanish (issue #69).
  # Net::HTTP stays opted out: in every semconv mode its CLIENT spans omit
  # `url.full`/`http.url`, and perf-sentinel classifies a span as HTTP I/O ONLY
  # when it carries one of those (ingest/otlp.rs classify_io_event), so its
  # spans are dropped as MissingHttpUrl and the HTTP anti-patterns never fire.
  # ApplicationController#http_get emits its own CLIENT span with `url.full`
  # instead (one clean span, no dup).
  # PG keeps statement literals (lab data is synthetic): the default obfuscation
  # turns redundant-sql's repeated `customer_id = 1` into `?`, which strict
  # classification cannot tell from an N+1.
  c.use_all(
    "OpenTelemetry::Instrumentation::Net::HTTP" => { enabled: false },
    "OpenTelemetry::Instrumentation::PG" => { db_statement: :include }
  )
end
