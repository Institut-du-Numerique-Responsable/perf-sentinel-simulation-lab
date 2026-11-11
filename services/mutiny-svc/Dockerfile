# Quarkus multistage Dockerfile for mutiny-svc. Identical strategy to
# services/quarkus-svc/Dockerfile: Eclipse Temurin JDK 25 for the
# Maven build, distroless OpenJDK 25 runtime, fast-jar layout. Only
# the resulting JAR set differs because mutiny-svc pulls a different
# set of Quarkus extensions (reactive PG client + reactive REST
# client instead of Panache/Hibernate JDBC).
#
# Build with:  docker build -t mutiny-svc:s2 services/mutiny-svc

FROM eclipse-temurin:25.0.5_8-jdk-alpine AS builder

WORKDIR /build
COPY pom.xml /build/pom.xml
RUN apk add --no-cache maven && \
    mvn -B -ntp dependency:go-offline -DskipTests || true

COPY src /build/src
RUN mvn -B -ntp package -DskipTests -Dquarkus.package.jar.type=fast-jar

FROM gcr.io/distroless/java25:nonroot

COPY --from=builder /build/target/quarkus-app/ /app/

EXPOSE 8084

USER 65532:65532

WORKDIR /app
ENTRYPOINT ["java", "-jar", "/app/quarkus-run.jar"]
