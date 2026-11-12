#!/usr/bin/env bash
# Build and deploy the three Java services into the shop namespace.
# Usage: ./scripts/seed-services.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CLUSTER_NAME="perf-sentinel-lab"
SERVICES=(order-service payment-service notification-service)
TAG="s2"

# shellcheck source=./k3d-image.sh
. "${REPO_ROOT}/scripts/k3d-image.sh"

color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PASSWORD_FILE="${REPO_ROOT}/.postgres-password"
if [ ! -f "${PASSWORD_FILE}" ]; then
  die "missing .postgres-password (run make up first)"
fi

step "Building Docker images for ${SERVICES[*]}"
for svc in "${SERVICES[@]}"; do
  docker build -q \
    -f "${REPO_ROOT}/services/shared-dockerfile/Dockerfile" \
    --build-arg SERVICE_NAME="${svc}" \
    -t "${svc}:${TAG}" \
    "${REPO_ROOT}/services/" >/dev/null
  ok "${svc}:${TAG} built"
done

step "Importing images into k3d cluster ${CLUSTER_NAME}"
mkdir -p "${REPO_ROOT}/tmp"
# `k3d image import` has been observed to return 0 even when one
# node silently misses the image (race or transient containerd
# error), which then surfaces 5 minutes later as ImagePullBackOff
# during `helm --wait`. Issue #9 traced exactly this on the CI
# multi-node cluster, so we verify with a 2s back-off retry and
# fail loud if the second pass still leaves a node short.
for svc in "${SERVICES[@]}"; do
  image="${svc}:${TAG}"
  import_log="${REPO_ROOT}/tmp/import-${svc}.log"
  for attempt in 1 2; do
    k3d image import "${image}" -c "${CLUSTER_NAME}" \
      > "${import_log}" 2>&1 || true
    if diag="$(verify_k3d_image_on_all_nodes "${CLUSTER_NAME}" "${image}")"; then
      ok "${svc}:${TAG} imported on all nodes"
      break
    fi
    if [ "${attempt}" -eq 1 ]; then
      color_yellow "    retry in 2s: ${image} not yet ready ($(echo "${diag}" | tr '\n' ' '))"
      sleep 2
    else
      color_red "    error: ${image} still not ready after retry ($(echo "${diag}" | tr '\n' ' '))"
      color_red "    import log: ${import_log}"
      die "k3d image import unreliable, helm install would hang on ImagePullBackOff"
    fi
  done
done

step "Helm upgrade --install for the 3 charts"
for svc in "${SERVICES[@]}"; do
  # --set-file reads the password from disk so it never appears in argv
  # (visible to ps aux) or shell history.
  deploy_rebuilt shop "${svc}" helm upgrade --install "${svc}" "${REPO_ROOT}/services/${svc}/helm/" \
    -n shop \
    --set-file "database.password=${PASSWORD_FILE}" \
    --wait --timeout 5m >/dev/null
  ok "${svc} deployed"
done

step "Waiting for shop deployments"
kubectl wait deployment --all -n shop \
  --for=condition=Available --timeout=180s

step "Services ready"
kubectl get pods -n shop
