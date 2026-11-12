#!/usr/bin/env bash
# Build, import, and helm-install the Quarkus multistack pilot
# (services/quarkus-svc). Mirrors scripts/seed-services.sh but
# stack-specific:
#   - own Dockerfile at services/quarkus-svc/Dockerfile (not the
#     shared Spring Boot multistage)
#   - own helm chart at services/quarkus-svc/helm/
#   - password sourced from .postgres-password the same way
#
# Usage: ./scripts/seed-quarkus-svc.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CLUSTER_NAME="perf-sentinel-lab"
SVC="quarkus-svc"
TAG="s2"
IMAGE="${SVC}:${TAG}"

# shellcheck source=./k3d-image.sh
. "${REPO_ROOT}/scripts/k3d-image.sh"

color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

# Database password for the multistack Postgres role `quarkus_user`.
# The role itself is created by manifests/postgres-multistack-schemas.yaml
# with password `lab_quarkus`. The Helm chart's values.yaml defaults to
# that password. This script overrides via --set if the operator wants
# to rotate the placeholder.
PASSWORD_FILE="${REPO_ROOT}/.postgres-quarkus-svc-password"
if [ ! -f "${PASSWORD_FILE}" ]; then
  # Initialise the file with the canonical lab placeholder. Keep it on
  # disk so subsequent helm upgrades reuse the same value and so
  # `make psql` works without prompting.
  printf 'lab_quarkus' > "${PASSWORD_FILE}"
  chmod 600 "${PASSWORD_FILE}"
  color_yellow "    note: created ${PASSWORD_FILE} with the canonical placeholder"
fi

step "Building Docker image ${IMAGE}"
docker build -q \
  -f "${REPO_ROOT}/services/${SVC}/Dockerfile" \
  -t "${IMAGE}" \
  "${REPO_ROOT}/services/${SVC}" >/dev/null
ok "${IMAGE} built"

step "Importing image into k3d cluster ${CLUSTER_NAME}"
mkdir -p "${REPO_ROOT}/tmp"
import_log="${REPO_ROOT}/tmp/import-${SVC}.log"
for attempt in 1 2; do
  k3d image import "${IMAGE}" -c "${CLUSTER_NAME}" \
    > "${import_log}" 2>&1 || true
  if diag="$(verify_k3d_image_on_all_nodes "${CLUSTER_NAME}" "${IMAGE}")"; then
    ok "${IMAGE} imported on all nodes"
    reclaim_local_docker_image "${IMAGE}"
    break
  fi
  if [ "${attempt}" -eq 1 ]; then
    color_yellow "    retry in 2s: ${IMAGE} not yet ready ($(echo "${diag}" | tr '\n' ' '))"
    sleep 2
  else
    color_red "    error: ${IMAGE} still not ready after retry ($(echo "${diag}" | tr '\n' ' '))"
    color_red "    import log: ${import_log}"
    die "k3d image import unreliable"
  fi
done

step "Helm upgrade --install ${SVC}"
deploy_rebuilt shop "${SVC}" helm upgrade --install "${SVC}" "${REPO_ROOT}/services/${SVC}/helm/" \
  -n shop \
  --set-file "database.password=${PASSWORD_FILE}" \
  --wait --timeout 5m >/dev/null
ok "${SVC} deployed"

step "Waiting for shop deployment ${SVC}"
kubectl wait deployment "${SVC}" -n shop \
  --for=condition=Available --timeout=180s

step "${SVC} ready"
kubectl get pod -n shop -l "app.kubernetes.io/name=${SVC}"
