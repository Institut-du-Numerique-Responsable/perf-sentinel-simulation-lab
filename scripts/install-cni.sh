#!/usr/bin/env bash
# Install Cilium 1.19.4 on a freshly created k3d cluster (Flannel
# disabled in cluster/k3d-config.yaml). Calico is documented as a
# manual fallback in case Cilium does not stabilize on Docker Desktop
# arm64. The active CNI name is written to cluster/.cni-active so
# downstream scripts can adapt their CRD apiVersion.
#
# Usage: ./scripts/install-cni.sh [cilium|calico]
#   default: cilium
#
# kubeProxyReplacement is left at its default value (false) because
# Docker Desktop's host networking layer is not stable enough to host
# Cilium's full kube-proxy replacement on arm64. The lab keeps the
# k3s-bundled kube-proxy and lets Cilium run alongside it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CNI="${1:-cilium}"
CNI_MARKER="${REPO_ROOT}/cluster/.cni-active"
CILIUM_VERSION="1.20.4"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

# k3d returns from `cluster create` before the k3s API server is fully up,
# so helm preflight can race a 503 "kubernetes cluster unreachable" window.
# /healthz alone is insufficient because it can flip green before the
# discovery aggregator is serving /apis.
step "Waiting for the Kubernetes API server to be reachable"
api_attempts=60
for attempt in $(seq 1 "${api_attempts}"); do
  if kubectl get --raw='/readyz' >/dev/null 2>&1 \
      && kubectl get --raw='/apis' >/dev/null 2>&1 \
      && kubectl get --request-timeout=5s namespace kube-system >/dev/null 2>&1; then
    ok "API server reachable"
    break
  fi
  if [ "${attempt}" -eq "${api_attempts}" ]; then
    die "API server not reachable after ${api_attempts} attempts (~120s)"
  fi
  sleep 2
done

case "${CNI}" in
  cilium)
    step "Installing Cilium ${CILIUM_VERSION} via Helm"
    # Add the cilium repo with retries. helm.cilium.io occasionally
    # returns 5xx or times out from GitHub-hosted runners and the
    # previous `|| true` swallowed those errors, leaving the next
    # `helm repo update` to fail loudly with "no repositories matching
    # 'cilium'" (observed on scheduled run 26202794690, 2026-05-21).
    add_attempts=3
    for attempt in $(seq 1 "${add_attempts}"); do
      if helm repo add cilium https://helm.cilium.io; then
        break
      fi
      if [ "${attempt}" -eq "${add_attempts}" ]; then
        die "helm repo add cilium failed after ${add_attempts} attempts"
      fi
      color_red "    helm repo add cilium attempt ${attempt}/${add_attempts} failed, retrying in 5s"
      sleep 5
    done
    helm repo update cilium

    # Retry to absorb residual 503 flickers right after the readiness gate.
    # --atomic rolls back partial installs so retries don't hit
    # "another operation in progress" / "name in use".
    install_attempts=3
    for attempt in $(seq 1 "${install_attempts}"); do
      if helm upgrade --install cilium cilium/cilium \
          --namespace kube-system \
          --version "${CILIUM_VERSION}" \
          --set kubeProxyReplacement=false \
          --set hubble.enabled=true \
          --set hubble.relay.enabled=true \
          --set hubble.ui.enabled=false \
          --atomic --wait --timeout 5m; then
        break
      fi
      if [ "${attempt}" -eq "${install_attempts}" ]; then
        die "helm upgrade --install cilium failed after ${install_attempts} attempts"
      fi
      color_red "    helm upgrade --install cilium attempt ${attempt}/${install_attempts} failed, retrying in 10s"
      sleep 10
    done

    step "Waiting for Cilium agents Ready"
    kubectl -n kube-system rollout status daemonset/cilium --timeout=120s
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=120s
    ok "Cilium ${CILIUM_VERSION} ready"
    printf 'cilium\n' > "${CNI_MARKER}"
    ;;
  calico)
    step "Installing Calico via tigera-operator (fallback path)"
    # NOTE: this path is documented but not exercised end-to-end in
    # this lab. Tigera operator alone does not bring Calico up. You
    # also need to apply an `Installation` custom resource (cf.
    # https://docs.tigera.io/calico/latest/getting-started/kubernetes/helm).
    # The current implementation installs the operator only. Flesh
    # out the Installation CR before running this branch in anger.
    helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
    helm repo update projectcalico >/dev/null
    helm upgrade --install calico projectcalico/tigera-operator \
      --namespace tigera-operator --create-namespace \
      --version v3.33.0 \
      --wait --timeout 5m
    step "Waiting for Calico nodes Ready"
    kubectl -n calico-system rollout status daemonset/calico-node --timeout=180s
    ok "Calico ready"
    printf 'calico\n' > "${CNI_MARKER}"
    ;;
  *)
    die "unsupported CNI: ${CNI}. Pass cilium or calico."
    ;;
esac

color_green ""
color_green "CNI active: ${CNI} (marker: ${CNI_MARKER})"
color_green "Next: ./scripts/bootstrap.sh, then make apply-network-policies"
