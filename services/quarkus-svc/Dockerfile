# Quarkus multistage Dockerfile for quarkus-svc. Three stages, aligned
# on the Spring Boot baseline `services/shared-dockerfile/Dockerfile`:
#   1. Fetch the OpenTelemetry Java agent v2.33. Required because the
#      `quarkus-opentelemetry` extension instruments JDBC but does NOT
#      emit the `org.hibernate.*` scope marker that perf-sentinel's
#      strict sanitizer-aware classifier needs to reclassify a
#      sanitized SQL batch as n_plus_one_sql. The Java agent does emit
#      it, and is the deployment shape most prod operators run on
#      Quarkus anyway.
#   2. Maven build with Eclipse Temurin JDK 25, produces the fast-jar.
#   3. Distroless OpenJDK 25 runtime with the agent mounted at /otel/,
#      activated through JAVA_TOOL_OPTIONS exactly like the Spring Boot
#      shared Dockerfile.
#
# Build with:  docker build -t quarkus-svc:s2 services/quarkus-svc

# ---- otel agent download ----
FROM alpine:3.24 AS otel-agent
ARG OTEL_AGENT_VERSION=2.33.1
# SHA-256 published for the v2.33.1 release asset and verified against
# the downloaded JAR. Fails the build if the upstream asset changes.
ARG OTEL_AGENT_SHA256=e43a270df53c6f423e0ab157be9c27ccc01d5dc3232e162fe54777573db2f149
RUN apk add --no-cache wget \
 && wget -q -O /opentelemetry-javaagent.jar \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
 && echo "${OTEL_AGENT_SHA256}  /opentelemetry-javaagent.jar" | sha256sum -c -

# ---- builder ----
FROM eclipse-temurin:25.0.5_8-jdk-alpine AS builder

WORKDIR /build
COPY pom.xml /build/pom.xml
# Pre-fetch dependencies so layer cache stays warm across source edits.
RUN apk add --no-cache maven && \
    mvn -B -ntp dependency:go-offline -DskipTests || true

COPY src /build/src
RUN mvn -B -ntp package -DskipTests -Dquarkus.package.jar.type=fast-jar

# ---- runtime ----
FROM gcr.io/distroless/java25-debian13:nonroot

# quarkus-fast-jar layout: target/quarkus-app/{quarkus-run.jar,lib,quarkus,app}
COPY --from=builder /build/target/quarkus-app/ /app/
COPY --from=otel-agent /opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar

# The OTel Java agent reads its config from OTEL_* env vars at startup
# and auto-instruments JDBC + Hibernate ORM + HikariCP/Agroal +
# RestClient + JAX-RS — including the scope markers perf-sentinel
# uses for n+1 reclassification. The quarkus-opentelemetry extension
# is still on the classpath (its dependency stays in pom.xml so the
# Quarkus context API works in application code), but the Java agent
# is the one that produces spans at runtime.
ENV JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"

EXPOSE 8083

USER 65532:65532

WORKDIR /app
ENTRYPOINT ["java", "-jar", "/app/quarkus-run.jar"]
