# fastapi-svc Dockerfile. Single-stage (python slim for asyncpg binary).
# Build with:  docker build -t fastapi-svc:s1 services/fastapi-svc

FROM python:3.15-slim-bookworm

RUN useradd -r -u 65532 -d /app nonroot
WORKDIR /app

COPY requirements.txt requirements.lock ./
RUN test "$(sha256sum requirements.txt | cut -d ' ' -f 1)" = "$(sed -n 's/^# requirements-sha256: //p' requirements.lock)" \
    && pip install --no-cache-dir --require-hashes -r requirements.lock

COPY app ./app

EXPOSE 8092
USER 65532:65532

ENV PYTHONDONTWRITEBYTECODE=1
# exec so uvicorn is PID 1 and receives SIGTERM directly from
# Kubernetes (shell form without exec leaves /bin/sh as PID 1 which
# does not forward signals → lifespan shutdown never runs).
CMD exec uvicorn app.main:app \
    --host 0.0.0.0 --port ${HTTP_PORT:-8092} \
    --workers 2 --timeout-keep-alive 120
