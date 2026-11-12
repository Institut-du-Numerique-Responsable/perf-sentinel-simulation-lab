# rails-svc multistage Dockerfile.
#
#   1. ruby:4.0-slim-trixie builder: build toolchain + libpq-dev to compile
#      the pg and OpenTelemetry C extensions, then bundle install.
#   2. Same slim image as runtime (distroless ruby does not exist with the
#      native gem deps; slim-trixie + libpq5 is the pragmatic choice, like
#      django-svc).
#
# Build with:  docker build -t rails-svc:s4 services/rails-svc
FROM ruby:4.0-slim-trixie AS builder
WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4 --retry 3

COPY . .

FROM ruby:4.0-slim-trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -r -u 65532 -d /app nonroot

WORKDIR /app
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /app /app

# Rails wants a writable tmp/; the pod root filesystem is read-only and mounts
# an emptyDir at /tmp, so route ./tmp there.
RUN rm -rf /app/tmp && ln -s /tmp /app/tmp

EXPOSE 8094
USER 65532:65532

ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1

# puma reads HTTP_PORT (injected by the helm deployment) via config/puma.rb.
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "config.ru"]
