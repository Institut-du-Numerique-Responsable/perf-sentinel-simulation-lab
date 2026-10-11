# seaorm-svc Dockerfile. SeaORM uses sqlx (pure Rust + rustls) —
# no libpq C dependency, unlike diesel-svc. Lighter runtime.
FROM rust:1.99-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
RUN mkdir src && echo 'fn main(){}' > src/main.rs && cargo build --release 2>/dev/null || true
COPY src ./src
RUN touch src/main.rs && cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 65532 -d /app nonroot
WORKDIR /app
COPY --from=builder /build/target/release/seaorm-svc /app/seaorm-svc
EXPOSE 8089
USER 65532:65532
ENTRYPOINT ["/app/seaorm-svc"]
