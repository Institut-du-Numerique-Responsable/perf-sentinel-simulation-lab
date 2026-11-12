# go-svc multistage Dockerfile.
#
#   1. golang:1.27-trixie builder, CGO_ENABLED=0 so the resulting
#      binary is fully static and runs on the distroless/static
#      runtime image with no glibc dependency.
#   2. gcr.io/distroless/static-debian13:nonroot runtime — published
#      non-root identity at UID/GID 65532. No shell, no package
#      manager, just the binary.
#
# Build with:  docker build -t go-svc:s1 services/go-svc

# ---- builder ----
FROM golang:1.27-trixie AS builder

WORKDIR /src

# Resolve module graph first for layer cache. The go.sum is written
# here too (the repo ships only go.mod, the build re-resolves on
# every cold build).
COPY go.mod ./
RUN go mod download

COPY . ./

# Static binary, stripped, CGO off so distroless/static can host it.
RUN CGO_ENABLED=0 GOFLAGS="-trimpath" go build \
        -ldflags="-s -w" \
        -o /out/go-svc \
        ./

# ---- runtime ----
FROM gcr.io/distroless/static-debian13:nonroot

COPY --from=builder /out/go-svc /app/go-svc

EXPOSE 8093
USER 65532:65532

ENTRYPOINT ["/app/go-svc"]
