# syntax=docker/dockerfile:1
# Shared multistage Dockerfile for the three Spring Boot services.
# Build with: docker build -f services/shared-dockerfile/Dockerfile \
#   --build-arg SERVICE_NAME=order-service \
#   -t order-service:s2 services/

# Stage 1: download the OpenTelemetry Java agent. Cached independently
# from the maven build so source changes do not refetch the jar.
FROM alpine:3.24 AS otel-agent
ARG OTEL_AGENT_VERSION=2.33.1
ARG OTEL_AGENT_SHA256=e43a270df53c6f423e0ab157be9c27ccc01d5dc3232e162fe54777573db2f149
RUN apk add --no-cache wget \
 && wget -q -O /opentelemetry-javaagent.jar \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
 && echo "${OTEL_AGENT_SHA256}  /opentelemetry-javaagent.jar" | sha256sum -c -

# Stage 2: maven build. The parent pom declares all 3 service modules,
# so we copy all of them even when building only one. With `-pl
# ${SERVICE_NAME} -am` Maven still only compiles the requested module
# plus its dependencies (shared-config).
FROM eclipse-temurin:25.0.5_8-jdk-alpine AS builder
ARG SERVICE_NAME
WORKDIR /build
COPY .mvn .mvn
COPY mvnw pom.xml ./
COPY shared-config shared-config
COPY order-service order-service
COPY payment-service payment-service
COPY notification-service notification-service
# The .m2 cache mount is what keeps this from re-downloading the whole
# dependency tree on every build. Without it each of the three services pays a
# full cold resolve, because SERVICE_NAME is a build arg and therefore changes
# this layer's cache key: three services, three cold downloads. `sharing=locked`
# so two concurrent builds cannot corrupt the local repository.
RUN --mount=type=cache,target=/root/.m2,sharing=locked \
    chmod +x mvnw \
 && ./mvnw -B -DskipTests -pl ${SERVICE_NAME} -am package
RUN cp ${SERVICE_NAME}/target/${SERVICE_NAME}-*.jar /build/app.jar

# Stage 3: distroless runtime. No shell, nonroot user (UID 65532).
FROM gcr.io/distroless/java25-debian13:nonroot
COPY --from=builder /build/app.jar /app/app.jar
COPY --from=otel-agent /opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar
ENV JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
EXPOSE 8080 8081 8082
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
