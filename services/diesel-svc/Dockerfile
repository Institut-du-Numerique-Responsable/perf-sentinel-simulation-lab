# diesel-svc multistage Dockerfile.
#   1. rust:1.95-bookworm builder with libpq-dev for diesel pg.
#   2. debian:bookworm-slim runtime (diesel links libpq dynamically).
# Build with:  docker build -t diesel-svc:s1 services/diesel-svc

FROM rust:1.99-bookworm AS builder
RUN apt-get update && apt-get install -y libpq-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
RUN mkdir src && echo 'fn main(){}' > src/main.rs && cargo build --release 2>/dev/null || true
COPY src ./src
RUN touch src/main.rs && cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 65532 -d /app nonroot
WORKDIR /app
COPY --from=builder /build/target/release/diesel-svc /app/diesel-svc

EXPOSE 8088
USER 65532:65532
ENTRYPOINT ["/app/diesel-svc"]
