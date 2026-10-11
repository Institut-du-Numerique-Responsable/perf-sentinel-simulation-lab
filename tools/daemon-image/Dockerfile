# Build a local perf-sentinel daemon image from a source checkout, for
# pre-release validation before the GHCR image exists. Build context must
# be the perf-sentinel repository root (scripts/seed-daemon-local.sh).
# Mirrors the release image: static musl binary, FROM scratch, same
# allocator path (musl -> mimalloc) as the published binaries.
FROM rust:1.99-alpine AS build
RUN apk add --no-cache build-base musl-dev
# Optional cap on rustc parallelism for a host short on memory, passed by
# scripts/seed-daemon-local.sh from DAEMON_BUILD_JOBS. Unset means cargo's default.
ARG CARGO_BUILD_JOBS
WORKDIR /src
COPY . .
RUN cargo build --release -p perf-sentinel --locked ${CARGO_BUILD_JOBS:+-j ${CARGO_BUILD_JOBS}}

FROM scratch
COPY --from=build /src/target/release/perf-sentinel /perf-sentinel
USER 65534
EXPOSE 4317 4318
ENTRYPOINT ["/perf-sentinel"]
CMD ["watch"]
