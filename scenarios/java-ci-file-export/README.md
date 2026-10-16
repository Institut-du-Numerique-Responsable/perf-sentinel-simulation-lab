# java-ci-file-export

The Java agent inside a forked Failsafe JVM writes OTLP JSON Lines straight to
`target/traces.jsonl`, and `perf-sentinel analyze --ci` reads that file. No
`perf-sentinel capture`, no receiver, no port, nothing on the fork's stdout.

## Why it exists

Until now a Java CI job could not produce a trace file on its own. The
exporter that writes OTLP JSON (`otlp_file/development`, the
`experimental-otlp/stdout` of the autoconfigure world) could only write to
stdout, and a forked Failsafe JVM cannot hand its stdout back
(`java-ci-capture`, round 1). That is why the upstream recipe wraps the test
command in `perf-sentinel capture`.

OpenTelemetry Java **SDK 1.66.0** (2026-09-11, open-telemetry/opentelemetry-java
#8676) wires `output_stream: file:///...` into that exporter. Two constraints
come with it:

- **Declarative configuration only.** The option is reachable from a YAML file
  named by `OTEL_CONFIG_FILE`, not from any `OTEL_*` variable. Once that file is
  set, the agent ignores the `OTEL_*` variables entirely.
- **Agent 2.32.0 or later.** Agent 2.31.1 bundles SDK 1.65. The first agent
  with 1.66 is 2.32.0, pinned here from Maven Central.

It is **not** the OpenTelemetry Maven extension
(`io.opentelemetry.contrib:opentelemetry-maven-extension`, 1.60.0-alpha at the
time of writing). That extension traces the build itself (sessions, projects,
mojo executions), exports OTLP only, and its spans carry no I/O attribute, so
perf-sentinel would drop them as `not_io` anyway.

## Configuration

The `otel-file` profile of the shared fixture
(`scenarios/java-ci-capture/fixtures/pom.xml`) does three things. It pins the
agent through `lab.otel.file.agent.version`, it points the fork at
`fixtures/otel-file.yaml` through `OTEL_CONFIG_FILE`, and it passes the output
path as `LAB_TRACES_FILE`, which the YAML expands:

```yaml
file_format: "1.1"
tracer_provider:
  processors:
    - simple:
        exporter:
          otlp_file/development:
            output_stream: file://${LAB_TRACES_FILE}
```

The `simple` processor writes one line per span as it ends, so nothing waits
on a batch at JVM exit. The CI step is then just the test command:

```bash
rm -f target/traces.jsonl
mvn -B -P otel-file verify
perf-sentinel analyze --ci --input target/traces.jsonl
```

## What it asserts

| id | assertion |
|----|-----------|
| E1 | `mvn verify` is green with **nothing listening** on 4317/4318, the file is non-empty OTLP JSON Lines, and its resource names the SDK that wrote it |
| E2 | the fork is untouched: no `Corrupted channel`, no `.dumpstream`, no span on Maven's stdout |
| E3 | `analyze --ci` on the file: 16 spans (15 JDBC + 1 SERVER) and `n_plus_one_sql` at 15 occurrences, the same counts `java-ci-capture` gets through `capture` |
| E4 | a second run without `clean` **appends**: the file doubles and `n_plus_one_sql` is reported twice |
| E5 | a failing test: Maven exits non-zero, and the file of the red run is still complete and analyzable |
| E6 | negative control, the same profile on agent **2.31.1**: `BUILD SUCCESS`, **no file**, spans diverted to the fork channel (`Corrupted channel` + `.dumpstream`) |

## What to take away for a pipeline

- **E6 is a silent zero.** On an agent older than 2.32, the YAML parses, the
  option is ignored, the build stays green, and the trace file is simply
  missing. Pin the agent version and keep the gate's missing-file error
  (`analyze` refuses a missing or empty input) as the backstop.
- **E4: start from an empty file.** The exporter opens the file in APPEND mode,
  following the spec's "streaming appending". A persistent workspace (Jenkins
  agent, self-hosted runner) that reruns the suite without `clean` hands
  perf-sentinel both runs, and the same finding is counted twice.
- **One JVM per file.** Upstream notes that several signals or processes
  writing the same path are not synchronized, so their lines can interleave.
  With `forkCount > 1`, give each fork its own path (`${surefire.forkNumber}`)
  and concatenate the files before `analyze`, which takes a single file.

## Prerequisites

No cluster. It needs the local release binary (`cargo build --release -p
perf-sentinel`), a JDK, Maven (or `services/mvnw`), Docker for the throwaway
PostgreSQL on `:15443`, and network access to Maven Central. Ports 4317/4318
must be free,
because E1 claims the export needs no receiver.

```bash
make verify-java-ci-file-export
```

Renovate's `maven` manager is disabled in this repository, so
`lab.otel.file.agent.version` in the fixture POM moves by hand.

The same no-capture step also runs in real CI engines, as legs H5
(`ci-e2e-github`), G5 (`ci-e2e-gitlab`) and J9 (`ci-e2e-jenkins`).
