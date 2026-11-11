# Helidon SE multistage Dockerfile. Same shape as the helidon-mp-svc and
# quarkus-svc Dockerfiles (OTel Java agent v2.30 + distroless java25),
# but no Narayana JTA properties since Helidon SE does not pull JTA in.
#
# Build with:  docker build -t helidon-se-svc:s2 services/helidon-se-svc

# ---- otel agent download ----
FROM alpine:3.24 AS otel-agent
ARG OTEL_AGENT_VERSION=2.30.0
ARG OTEL_AGENT_SHA256=9d6bc2ad8dd8fb7f730984988e57b8ac0a82d81c7b3b8ae795378718733a509d
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
FROM gcr.io/distroless/java25:nonroot

COPY --from=builder /build/target/helidon-se-svc.jar /app/helidon-se-svc.jar
COPY --from=builder /build/target/libs/ /app/libs/
COPY --from=otel-agent /opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar

ENV JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"

EXPOSE 8085

USER 65532:65532

WORKDIR /app
ENTRYPOINT ["java", "-jar", "/app/helidon-se-svc.jar"]
