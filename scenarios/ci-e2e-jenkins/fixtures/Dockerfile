# A real Jenkins controller carrying everything the documented Java CI recipe
# needs: Maven, a JDK, the released perf-sentinel binary, and the fixture
# project. Builds run on the controller itself — no agent — because what is
# under test is the recipe and how Jenkins SERVES the resulting report, not
# Jenkins' distributed build topology.

# The released image is FROM scratch with a single static binary at /perf-sentinel.
# Taking it from there rather than building locally is also more faithful: it is
# the artifact a user actually installs. Overridable so a pre-release validation
# can point at a locally built image instead of the last published one — the
# default must stay a real published tag, or a fresh clone builds nothing.
ARG PERF_SENTINEL_IMAGE=ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.11.2
FROM ${PERF_SENTINEL_IMAGE} AS perf-sentinel

# Latest LTS line as of 2026-08-01 (2.575 is the weekly, not the LTS), arm64-native.
FROM jenkins/jenkins:2.580.1-lts-jdk25

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends maven \
 && rm -rf /var/lib/apt/lists/*
COPY --from=perf-sentinel /perf-sentinel /usr/local/bin/perf-sentinel
USER jenkins

# workflow-aggregator: declarative pipeline. htmlpublisher: the plugin the
# upstream Jenkinsfile uses to expose the report, and the one whose served
# pages go through DirectoryBrowserSupport and therefore carry Jenkins' CSP.
RUN jenkins-plugin-cli --plugins \
      workflow-aggregator \
      htmlpublisher \
      configuration-as-code

# /usr/share/jenkins/ref is copied into JENKINS_HOME on first boot, which is how
# a job can be seeded without the Job DSL plugin.
COPY casc.yaml /usr/share/jenkins/ref/casc.yaml
COPY job-config.xml /usr/share/jenkins/ref/jobs/perf-sentinel-e2e/config.xml
COPY project /usr/share/jenkins/ref/perf-sentinel-project

ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc.yaml
# No setup wizard: this controller is a throwaway driven entirely by JCasC.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
