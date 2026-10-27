# django-svc multistage Dockerfile.
#
#   1. python:3.14-slim-bookworm builder: pip install + collectstatic.
#   2. Same slim image as runtime (distroless python3 lacks pip and
#      psycopg binary deps — slim-bookworm is the pragmatic choice for
#      Django + psycopg[binary]).
#
# Build with:  docker build -t django-svc:s1 services/django-svc

FROM python:3.15-slim-bookworm AS builder
WORKDIR /app

COPY requirements.txt requirements.lock ./
RUN test "$(sha256sum requirements.txt | cut -d ' ' -f 1)" = "$(sed -n 's/^# requirements-sha256: //p' requirements.lock)" \
    && pip install --no-cache-dir --require-hashes -r requirements.lock

COPY djangosvc ./djangosvc

FROM python:3.15-slim-bookworm

RUN useradd -r -u 65532 -d /app nonroot
WORKDIR /app

COPY --from=builder /usr/local/lib/python3.14/site-packages /usr/local/lib/python3.14/site-packages
COPY --from=builder /usr/local/bin/gunicorn /usr/local/bin/gunicorn
COPY --from=builder /app /app

EXPOSE 8091
USER 65532:65532

ENV PYTHONDONTWRITEBYTECODE=1
# Shell form so ${HTTP_PORT} is expanded at runtime (exec form does
# not do shell variable expansion). Matches the HTTP_PORT env var
# injected by the helm deployment template.
# 20 slots (2x10), matching PHP_CLI_SERVER_WORKERS=20 on the PHP stacks: the HTTP
# faults self-call this same server, so a parent request holds one slot while
# waiting on its own child. At 2x4 the k6 load (5 VUs -> 10 concurrent) starved
# those children into the 15s client timeout, which the daemon then classified as
# slow_http instead of n_plus_one_http (issue #102).
CMD gunicorn djangosvc.wsgi:application \
    --bind "0.0.0.0:${HTTP_PORT:-8091}" \
    --workers 2 --threads 10 --timeout 120 \
    --worker-tmp-dir /tmp
