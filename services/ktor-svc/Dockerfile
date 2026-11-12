FROM alpine:3.24 AS otel-agent
ARG OTEL_AGENT_VERSION=2.33.1
ARG OTEL_AGENT_SHA256=e43a270df53c6f423e0ab157be9c27ccc01d5dc3232e162fe54777573db2f149
RUN apk add --no-cache wget \
 && wget -q -O /opentelemetry-javaagent.jar \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
 && echo "${OTEL_AGENT_SHA256}  /opentelemetry-javaagent.jar" | sha256sum -c -

FROM eclipse-temurin:25.0.5_8-jdk-alpine AS builder
WORKDIR /build
COPY pom.xml ./
RUN apk add --no-cache maven \
 && mvn -B -ntp dependency:go-offline -DskipTests
COPY src ./src
RUN mvn -B -ntp package -DskipTests

FROM gcr.io/distroless/java25-debian13:nonroot
COPY --from=builder /build/target/ktor-svc.jar /app/ktor-svc.jar
COPY --from=builder /build/target/libs/ /app/libs/
COPY --from=otel-agent /opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar
ENV JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
EXPOSE 8097
USER 65532:65532
WORKDIR /app
ENTRYPOINT ["java", "-jar", "/app/ktor-svc.jar"]
