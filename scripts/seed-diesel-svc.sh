#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
CLUSTER_NAME="perf-sentinel-lab"
SVC="diesel-svc"; TAG="s2"; IMAGE="${SVC}:${TAG}"
. "${REPO_ROOT}/scripts/k3d-image.sh"
color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }
PASSWORD_FILE="${REPO_ROOT}/.postgres-diesel-svc-password"
if [ ! -f "${PASSWORD_FILE}" ]; then
  printf 'lab_diesel' > "${PASSWORD_FILE}"; chmod 600 "${PASSWORD_FILE}"
  color_yellow "    note: created ${PASSWORD_FILE}"
fi
step "Building Docker image ${IMAGE}"
docker build -q -f "${REPO_ROOT}/services/${SVC}/Dockerfile" -t "${IMAGE}" "${REPO_ROOT}/services/${SVC}" >/dev/null
ok "${IMAGE} built"
step "Importing image into k3d cluster ${CLUSTER_NAME}"
mkdir -p "${REPO_ROOT}/tmp"
import_log="${REPO_ROOT}/tmp/import-${SVC}.log"
for attempt in 1 2; do
  k3d image import "${IMAGE}" -c "${CLUSTER_NAME}" > "${import_log}" 2>&1 || true
  if diag="$(verify_k3d_image_on_all_nodes "${CLUSTER_NAME}" "${IMAGE}")"; then
    ok "${IMAGE} imported on all nodes"; reclaim_local_docker_image "${IMAGE}"; break
  fi
  if [ "${attempt}" -eq 1 ]; then
    color_yellow "    retry in 2s"; sleep 2
  else die "k3d image import unreliable"; fi
done
step "Helm upgrade --install ${SVC}"
deploy_rebuilt shop "${SVC}" helm upgrade --install "${SVC}" "${REPO_ROOT}/services/${SVC}/helm/" -n shop \
  --set-file "database.password=${PASSWORD_FILE}" --wait --timeout 5m >/dev/null
ok "${SVC} deployed"
step "Waiting for shop deployment ${SVC}"
kubectl wait deployment "${SVC}" -n shop --for=condition=Available --timeout=180s
step "${SVC} ready"
kubectl get pod -n shop -l "app.kubernetes.io/name=${SVC}"
