#!/usr/bin/env bash
# Bootstrap the perf-sentinel simulation lab.
# Usage: ./scripts/bootstrap.sh
# Requires: docker, k3d, kubectl, helm. Use `make up` from the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Pinned versions. Keep in sync with cluster/k3d-config.yaml (k3s image),
# scripts/install-cni.sh (cilium), manifests/tempo.yaml, helm/values/*.yaml
# comments, and docs/RESOURCES.md. The perf-sentinel image is derived from
# the deployment manifest so the daemon and bootstrap pre-pull never drift.
CLUSTER_NAME="perf-sentinel-lab"
# Match both tag pin (`...perf-sentinel:0.5.16`) and digest pin
# (`...perf-sentinel@sha256:abc...`); the manifest switched to digest in 0.5.18.
PERF_SENTINEL_IMAGE=$(awk '/^[[:space:]]*image:[[:space:]]*ghcr\.io\/institut-du-numerique-responsable\/perf-sentinel[:@]/ { print $2; exit }' \
  "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml")
# A pre-release validation leaves a LOCAL pin behind (`image: perf-sentinel:<ver>-<sha>`,
# see scripts/seed-daemon-local.sh), and that is a legitimate working-tree state.
# There is nothing to pre-pull or pre-import then: seed-daemon-local builds and
# imports the image itself, after the cluster exists. Dying here instead made
# `make up` impossible until the pin was reverted by hand, with an error that did
# not say so.
if [ -z "${PERF_SENTINEL_IMAGE}" ] \
   && grep -qE '^[[:space:]]*image:[[:space:]]*perf-sentinel:' \
        "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml"; then
  PERF_SENTINEL_IMAGE=""
  PERF_SENTINEL_LOCAL_PIN=1
fi
[ -n "${PERF_SENTINEL_IMAGE}" ] || [ "${PERF_SENTINEL_LOCAL_PIN:-0}" = "1" ] || {
  printf "\033[31m    error: failed to extract perf-sentinel image from manifests/perf-sentinel-daemon.yaml\033[0m\n" >&2
  printf "\033[31m           expected a ghcr.io/institut-du-numerique-responsable/perf-sentinel tag or digest, or a local perf-sentinel:<ver>-<sha> pin\033[0m\n" >&2
  exit 1
}
KPS_CHART_VERSION="92.3.0"
TEMPO_IMAGE_VERSION="3.0.0"
OTEL_CHART_VERSION="0.175.1"

# shellcheck source=./wait-for-ready.sh
. "${REPO_ROOT}/scripts/wait-for-ready.sh"
# shellcheck source=./k3d-image.sh
. "${REPO_ROOT}/scripts/k3d-image.sh"

color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }

step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_yellow "    warn: $*"; }
die()  { color_red "    error: $*"; exit 1; }

check_prereqs() {
  step "Checking prerequisites"
  command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Desktop or Colima."
  docker info >/dev/null 2>&1 || die "docker daemon not reachable. Start Docker first."
  command -v k3d >/dev/null 2>&1 || die "k3d not found. Run: brew install k3d"
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found. Run: brew install kubectl"
  command -v helm >/dev/null 2>&1 || die "helm not found. Run: brew install helm"
  command -v openssl >/dev/null 2>&1 || die "openssl not found."
  ok "all CLIs present"
}

pull_perf_sentinel_image() {
  if [ "${PERF_SENTINEL_LOCAL_PIN:-0}" = "1" ]; then
    step "Skipping perf-sentinel pre-pull"
    ok "manifest carries a local pre-release pin; seed-daemon-local builds and imports it"
    return
  fi
  step "Pulling perf-sentinel image ${PERF_SENTINEL_IMAGE}"
  # GHCR reads flake on hosted CI (transient DNS i/o timeouts). Retry with
  # back-off before giving up, same reflex as the k3d image import below.
  for attempt in 1 2 3; do
    if docker pull "${PERF_SENTINEL_IMAGE}"; then
      ok "image cached on host (kubelets will pull on demand)"
      return
    fi
    [ "${attempt}" -lt 3 ] && warn "pull attempt ${attempt} failed, retry in $((attempt * 5))s" && sleep "$((attempt * 5))"
  done
  die "failed to pull ${PERF_SENTINEL_IMAGE} after 3 attempts. Image private? Run: docker login ghcr.io"
}

create_cluster() {
  step "Creating k3d cluster ${CLUSTER_NAME}"
  if k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1; then
    ok "cluster ${CLUSTER_NAME} already exists, skipping creation"
    return
  fi
  k3d cluster create --config "${REPO_ROOT}/cluster/k3d-config.yaml"
  ok "cluster created"
}

import_image() {
  if [ "${PERF_SENTINEL_LOCAL_PIN:-0}" = "1" ]; then
    step "Skipping perf-sentinel image import"
    ok "manifest carries a local pre-release pin; seed-daemon-local imports it"
    return
  fi
  step "Importing perf-sentinel image into k3d (best effort)"
  # k3d image import has been flaky on Docker Desktop in some setups
  # (failed digest lookups). The manifest references the GHCR image
  # directly so kubelets can fall back to pulling on demand. We still
  # try the import (with a 2s back-off retry) to make the lab work
  # offline once the image is on the host.
  mkdir -p "${REPO_ROOT}/tmp"
  local import_log="${REPO_ROOT}/tmp/import-perf-sentinel.log"
  local diag
  for attempt in 1 2; do
    k3d image import "${PERF_SENTINEL_IMAGE}" -c "${CLUSTER_NAME}" \
      > "${import_log}" 2>&1 || true
    if diag="$(verify_k3d_image_on_all_nodes "${CLUSTER_NAME}" "${PERF_SENTINEL_IMAGE}")"; then
      ok "image imported on all nodes"
      return
    fi
    if [ "${attempt}" -eq 1 ]; then
      warn "retry in 2s: image not yet ready ($(echo "${diag}" | tr '\n' ' '))"
      sleep 2
    fi
  done
  warn "k3d image import partial after retry, kubelets will pull from GHCR (slower first start)"
  warn "diag: $(echo "${diag}" | tr '\n' ' ')"
  warn "import log: ${import_log}"
}

add_helm_repos() {
  step "Adding helm repos"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  ok "repos updated"
}

apply_namespaces() {
  step "Applying namespaces"
  kubectl apply -f "${REPO_ROOT}/manifests/namespaces.yaml"
  ok "namespaces applied"
}

generate_rabbitmq_secret() {
  step "Generating RabbitMQ credentials"
  local password_file="${REPO_ROOT}/.rabbitmq-password"
  local password
  if [ -f "${password_file}" ]; then
    chmod 0600 "${password_file}"
    password="$(cat "${password_file}")"
    ok "reusing password from .rabbitmq-password"
  else
    password="$(openssl rand -base64 24 | tr -cd '[:alnum:]')"
    [ -n "${password}" ] || die "generated RabbitMQ password is empty"
    umask 077
    printf "%s" "${password}" > "${password_file}"
    chmod 0600 "${password_file}"
    ok "password persisted to .rabbitmq-password (mode 0600, gitignored)"
  fi
  [ -n "${password}" ] || die ".rabbitmq-password is empty"
  for namespace in messaging shop; do
    kubectl -n "${namespace}" create secret generic rabbitmq-credentials \
      --from-literal=username=perfsim \
      --from-literal=password="${password}" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  ok "secret rabbitmq-credentials applied in messaging and shop"
}

generate_postgres_secret() {
  step "Generating postgres credentials"
  local password_file="${REPO_ROOT}/.postgres-password"
  local password
  if [ -f "${password_file}" ]; then
    password="$(cat "${password_file}")"
    ok "reusing password from .postgres-password"
  else
    password="$(openssl rand -base64 24 | tr -d '\n=+/')"
    umask 077
    printf "%s" "${password}" > "${password_file}"
    chmod 0600 "${password_file}"
    ok "password persisted to .postgres-password (mode 0600, gitignored)"
  fi
  kubectl -n db create secret generic postgres-credentials \
    --from-literal=username=lab \
    --from-literal=password="${password}" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "secret postgres-credentials applied"
}

# Echo the secret held in ${1}, generating and persisting it on first call.
# Nothing else may reach stdout: callers capture it.
persist_secret() {
  local file="$1"
  if [ ! -s "${file}" ]; then
    umask 077
    openssl rand -hex 24 > "${file}"
    chmod 0600 "${file}"
  fi
  tr -d '\n\r' < "${file}"
}

generate_perf_sentinel_api_keys() {
  step "Generating perf-sentinel API keys"
  # Two distinct keys in one Secret, both read by the daemon from the
  # environment. The incidents key gates POST /api/incidents, the read key
  # only opens the GETs that write key gates and is the one the Hub is handed,
  # so a poller can never fabricate an incident. Unlike the Electricity Maps
  # token these are not optional: the daemon exits at startup when
  # [daemon.incidents] is enabled and its key resolves to nothing, so the
  # Secret has to exist before the daemon is applied.
  # The files are named *.key because .gitignore already covers that suffix.
  local incidents_key read_key
  incidents_key="$(persist_secret "${REPO_ROOT}/.perf-sentinel-incidents.key")"
  read_key="$(persist_secret "${REPO_ROOT}/.perf-sentinel-read.key")"
  [ -n "${incidents_key}" ] && [ -n "${read_key}" ] || die "a generated perf-sentinel API key is empty"
  # The daemon refuses the pair when the two match, and it refuses it by
  # exiting, so catch it here where the message can say which file to delete.
  [ "${incidents_key}" != "${read_key}" ] \
    || die ".perf-sentinel-incidents.key and .perf-sentinel-read.key hold the same value. Delete one and re-run."
  kubectl -n observability create secret generic perf-sentinel-api-keys \
    --from-literal=incidents-api-key="${incidents_key}" \
    --from-literal=read-api-key="${read_key}" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "secret perf-sentinel-api-keys applied in observability"
}

deploy_postgres() {
  step "Deploying PostgreSQL"
  kubectl apply -f "${REPO_ROOT}/manifests/postgres-init-schemas.yaml"
  kubectl apply -f "${REPO_ROOT}/manifests/postgres.yaml"
  wait_for_statefulset db postgres 180s
  ok "postgres ready"
  # postgres-init-schemas only covers the three core services, and it runs
  # through docker-entrypoint-initdb.d, i.e. at first boot only. Without this
  # idempotent Job every `make seed-<stack>-svc` on a from-zero cluster dies on
  # `password authentication failed for user "<stack>_user"`.
  step "Creating multistack schemas and roles"
  kubectl delete job -n db postgres-multistack-schemas --ignore-not-found >/dev/null
  kubectl apply -f "${REPO_ROOT}/manifests/postgres-multistack-schemas.yaml"
  kubectl -n db wait --for=condition=complete job/postgres-multistack-schemas --timeout=180s
  ok "multistack schemas ready"
}

deploy_messaging() {
  step "Deploying RabbitMQ and Toxiproxy"
  kubectl apply -f "${REPO_ROOT}/manifests/messaging-rabbitmq.yaml"
  wait_for_deployment messaging rabbitmq 180s
  wait_for_deployment messaging toxiproxy 180s

  local remove_output
  if ! remove_output="$(kubectl -n messaging exec deployment/toxiproxy -- \
    /toxiproxy-cli toxic remove -n latency_downstream rabbitmq-slow 2>&1)"; then
    case "${remove_output}" in
      *"not found"*|*"does not exist"*) ;;
      *) color_red "${remove_output}"; return 1 ;;
    esac
  fi
  kubectl -n messaging exec deployment/toxiproxy -- \
    /toxiproxy-cli toxic add -t latency -n latency_downstream \
      -d -a latency=600 -a jitter=0 rabbitmq-slow
  kubectl -n messaging exec deployment/toxiproxy -- /toxiproxy-cli list
  ok "RabbitMQ and Toxiproxy ready"
}

deploy_kube_prometheus_stack() {
  step "Installing kube-prometheus-stack ${KPS_CHART_VERSION}"
  helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    -n observability \
    --version "${KPS_CHART_VERSION}" \
    -f "${REPO_ROOT}/helm/values/kube-prometheus-stack.yaml" \
    --wait --timeout 10m
  ok "kube-prometheus-stack deployed"
}

deploy_tempo() {
  step "Deploying Tempo ${TEMPO_IMAGE_VERSION} (single-binary, hand-written manifest)"
  kubectl apply -f "${REPO_ROOT}/manifests/tempo.yaml"
  kubectl rollout status statefulset tempo -n observability --timeout=180s
  ok "tempo deployed"
}

deploy_victoria_traces() {
  step "Deploying Victoria Traces (second trace backend, hand-written manifest)"
  kubectl apply -f "${REPO_ROOT}/manifests/victoria-traces.yaml"
  kubectl rollout status statefulset victoria-traces -n observability --timeout=180s
  ok "victoria-traces deployed"
}

deploy_otel_collector() {
  step "Installing OTel Collector ${OTEL_CHART_VERSION}"
  helm upgrade --install otel-collector \
    open-telemetry/opentelemetry-collector \
    -n observability \
    --version "${OTEL_CHART_VERSION}" \
    -f "${REPO_ROOT}/helm/values/otel-collector.yaml" \
    --wait --timeout 5m
  ok "otel-collector deployed"
}

deploy_grafana_dashboards() {
  step "Loading Grafana dashboards"
  kubectl create configmap perf-sentinel-dashboards \
    --from-file="${REPO_ROOT}/manifests/grafana-dashboards/" \
    -n observability \
    --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
    | kubectl apply -f -
  ok "dashboards configmap applied"
}

deploy_scaphandre_mock() {
  step "Deploying Scaphandre mock"
  # RAPL is not accessible on Apple Silicon nor on most cloud runners,
  # so the mock provides the metric the daemon scraper consumes
  # (`scaph_process_power_consumption_microwatts`) and lets the
  # `[green.scaphandre]` block in the daemon ConfigMap be exercised
  # without a real exporter. Deployed before the daemon so the very
  # first scraper tick at startup hits a Ready endpoint and no
  # transient `Scaphandre scrape failed` WARN appears in the log.
  kubectl apply -f "${REPO_ROOT}/manifests/scaphandre-mock.yaml" >/dev/null
  kubectl -n observability rollout status deployment/scaphandre-mock --timeout=120s
  ok "scaphandre mock ready"
}

deploy_measured_energy_mocks() {
  step "Deploying Kepler and Redfish mocks"
  # Same rationale as scaphandre-mock: the lab nodes have neither
  # eBPF perf counters (Kepler) nor BMC hardware (Redfish), so two
  # Python stdlib mocks stand in. Both daemon scrapers ([green.kepler]
  # and [green.redfish] in the ConfigMap) hit Ready endpoints at the
  # very first tick and no transient `unreachable` WARN appears in
  # the log on a fresh bootstrap.
  kubectl apply -f "${REPO_ROOT}/manifests/kepler-mock.yaml" >/dev/null
  kubectl apply -f "${REPO_ROOT}/manifests/redfish-mock.yaml" >/dev/null
  kubectl -n observability rollout status deployment/kepler-mock --timeout=120s
  kubectl -n observability rollout status deployment/redfish-mock --timeout=120s
  ok "kepler and redfish mocks ready"
}

deploy_perf_sentinel_daemon() {
  step "Deploying perf-sentinel daemon"
  kubectl apply -f "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml"
  if [ "${PERF_SENTINEL_LOCAL_PIN:-0}" = "1" ]; then
    # The pinned image does not exist in a fresh cluster yet, so waiting for the
    # rollout would time out for a reason that is not a fault. seed-daemon-local
    # builds, imports and rolls it.
    ok "manifest applied; rollout deferred to \`make seed-daemon-local\` (local pre-release pin)"
    return
  fi
  wait_for_deployment observability perf-sentinel-daemon 180s
  ok "perf-sentinel daemon ready"
}

start_port_forwards() {
  step "Starting host port-forwards"
  # k3d's loadbalancer port mappings target NodePort/LoadBalancer
  # services. Our services are ClusterIP and servicelb is disabled, so
  # we route the user's host traffic through kubectl port-forward.
  "${REPO_ROOT}/scripts/port-forward.sh" start
  # Wait for each port-forward to actually accept connections so a
  # `make status` immediately after `make up` does not race.
  local deadline=$(( $(date +%s) + 30 ))
  for endpoint in "localhost:3000" "localhost:14318" "localhost:3200"; do
    until curl -fsS --max-time 1 "http://${endpoint}" >/dev/null 2>&1 \
       || [ "$(date +%s)" -ge "${deadline}" ]; do
      sleep 0.5
    done
  done
  ok "port-forwards running (PIDs in tmp/pf-*.pid)"
}

print_summary() {
  step "Bootstrap complete"
  cat <<EOF

  Cluster:       ${CLUSTER_NAME}
  Namespaces:    observability, db, shop (empty), ci (empty)

  Access (via background kubectl port-forward):
    Grafana:           http://localhost:3000  (user: admin / password: admin)
    perf-sentinel API: http://localhost:14318
    Tempo query API:   http://localhost:3200
    Postgres password: see .postgres-password (or output above)
    Stop port-forwards: ./scripts/port-forward.sh stop

  Useful targets:
    make status     status of cluster + key endpoints (curl)
    make logs       tail logs of the observability namespace
    make grafana    open Grafana in the browser
    make psql       open a psql shell against the lab database
    make inspect    launch the perf-sentinel TUI (requires local binary)
    make down       teardown the cluster

EOF
}

main() {
  check_prereqs
  pull_perf_sentinel_image
  create_cluster
  import_image
  add_helm_repos
  apply_namespaces
  generate_rabbitmq_secret
  generate_postgres_secret
  generate_perf_sentinel_api_keys
  deploy_postgres
  deploy_messaging
  deploy_kube_prometheus_stack
  deploy_tempo
  # Before the collector: its traces pipeline exports to Victoria Traces, and an
  # exporter whose target does not exist retries forever, grows its sending queue
  # and pushes the collector past memory_limiter, which then refuses spans at the
  # receiver for the whole pipeline (the daemon included).
  deploy_victoria_traces
  deploy_otel_collector
  deploy_grafana_dashboards
  deploy_scaphandre_mock
  deploy_measured_energy_mocks
  deploy_perf_sentinel_daemon
  start_port_forwards
  print_summary
}

main "$@"
