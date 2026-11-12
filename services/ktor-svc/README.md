# ktor-svc

Kotlin 2.4.21 and Ktor 3.6.1 member of the perf-sentinel multistack lab.
It exposes the shared 12 fault endpoints, three business callbacks and two
health endpoints on port 8097.

```bash
mvn -B -ntp -f services/ktor-svc/pom.xml test
make seed-ktor-svc
scripts/run-multistack-scenario.sh ktor
scripts/run-multistack-scenario.sh ktor messaging
```
