# Helidon MP multistage Dockerfile for helidon-mp-svc. Three stages,
# aligned on the Spring Boot baseline `services/shared-dockerfile/Dockerfile`
# and the quarkus-svc Dockerfile:
#   1. Fetch + verify the OpenTelemetry Java agent v2.33. Helidon's
#      built-in telemetry instruments JAX-RS, but the Java agent is
#      what emits the `org.hibernate.*` scope marker that perf-sentinel's
#      strict classifier needs for the n+1 SQL reclassification path.
#      Pinned by SHA-256 (supply-chain hygiene).
#   2. Maven build with Eclipse Temurin JDK 25, produces the
#      `target/helidon-mp-svc.jar` thin-jar + `target/libs/` runtime classpath.
#   3. Distroless OpenJDK 25 runtime, agent attached via JAVA_TOOL_OPTIONS.
#
# Build with:  docker build -t helidon-mp-svc:s2 services/helidon-mp-svc

# ---- otel agent download ----
FROM alpine:3.24 AS otel-agent
ARG OTEL_AGENT_VERSION=2.33.1
ARG OTEL_AGENT_SHA256=e43a270df53c6f423e0ab157be9c27ccc01d5dc3232e162fe54777573db2f149
RUN apk add --no-cache wget \
 && wget -q -O /opentelemetry-javaagent.jar \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
 && echo "${OTEL_AGENT_SHA256}  /opentelemetry-javaagent.jar" | sha256sum -c -

# ---- builder ----
FROM eclipse-temurin:25.0.5_8-jdk-alpine AS builder

WORKDIR /build
COPY pom.xml /build/pom.xml
RUN apk add --no-cache maven && \
    mvn -B -ntp dependency:go-offline -DskipTests || true

COPY src /build/src
RUN mvn -B -ntp package -DskipTests

# ---- runtime ----
FROM gcr.io/distroless/java25-debian13:nonroot

COPY --from=builder /build/target/helidon-mp-svc.jar /app/helidon-mp-svc.jar
COPY --from=builder /build/target/libs/ /app/libs/
COPY --from=otel-agent /opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar

# JAVA_TOOL_OPTIONS bundles:
#   1. The OTel Java agent (Hibernate scope marker for n+1 reclassification).
#   2. Narayana / Arjuna JTA ObjectStore redirected to /tmp/arjuna, which is
#      the emptyDir mount that's writable under the deployment's
#      readOnlyRootFilesystem securityContext. Without these properties
#      Narayana crashes at startup trying to spin up the
#      ShadowNoFileLockStore on the read-only root.
#   3. Disable the Narayana TransactionStatusManager TCP listener — the
#      pod's NetworkPolicy denies that and the recovery thread spins.
ENV JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar \
  -Dcom.arjuna.ats.arjuna.objectstore.objectStoreDir=/tmp/arjuna \
  -Dcom.arjuna.ats.arjuna.common.varDir=/tmp/arjuna \
  -Dcom.arjuna.ats.arjuna.coordinator.transactionStatusManagerEnable=false"

EXPOSE 8086

USER 65532:65532

WORKDIR /app
ENTRYPOINT ["java", "-jar", "/app/helidon-mp-svc.jar"]
