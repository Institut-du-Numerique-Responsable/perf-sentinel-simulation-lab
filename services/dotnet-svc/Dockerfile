# dotnet-svc multistage Dockerfile.
#
#   1. SDK builder image: restore + publish a self-contained framework-
#      dependent app. Trimming OFF — keeps the OTel ActivitySources
#      visible (trimming would prune the EF Core instrumentation
#      diagnostic listener and we'd lose the ORM scope marker).
#   2. Chiseled distroless runtime: mcr.microsoft.com/dotnet/runtime-deps
#      shipped by Microsoft, no shell, no libc surface beyond what the
#      runtime needs. UID/GID 1654 are the published `app` non-root
#      identity.
#
# Build with:  docker build -t dotnet-svc:s1 services/dotnet-svc

# ---- builder ----
FROM mcr.microsoft.com/dotnet/sdk:10.0-resolute AS builder
WORKDIR /src

# Restore first for layer cache. Copy the project and lock file so the
# package graph survives subsequent source edits. No RID — the published
# framework-dependent assemblies are portable and run on whatever
# architecture the runtime image lands on (k3d on Mac M-series is
# arm64, k3d on Linux x86_64 hosts is amd64).
COPY DotnetSvc.csproj packages.lock.json ./
RUN dotnet restore DotnetSvc.csproj --locked-mode

COPY . ./
RUN dotnet publish DotnetSvc.csproj \
        -c Release \
        --no-restore \
        -o /app/publish

# ---- runtime ----
FROM mcr.microsoft.com/dotnet/aspnet:10.0-resolute-chiseled-extra AS runtime

WORKDIR /app
COPY --from=builder /app/publish /app

EXPOSE 8087
USER 1654:1654

ENTRYPOINT ["dotnet", "/app/dotnet-svc.dll"]
