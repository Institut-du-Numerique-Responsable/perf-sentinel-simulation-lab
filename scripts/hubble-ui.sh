#!/usr/bin/env bash
# Enable the Hubble UI on a running Cilium installation, then expose it
# on http://localhost:12000. The UI is off by default to keep the lab
# footprint small. Turn it on when debugging NetworkPolicy denials.
# Usage: ./scripts/hubble-ui.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CNI_MARKER="${REPO_ROOT}/cluster/.cni-active"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

[ -f "${CNI_MARKER}" ] || die "CNI marker missing. Run make up-cni first."
[ "$(cat "${CNI_MARKER}")" = "cilium" ] \
  || die "Hubble UI is Cilium-only. Active CNI: $(cat "${CNI_MARKER}")"

step "Enabling Hubble UI in the Cilium release"
# Defensive helm repo add: a fresh shell session may not have the
# cilium repo cached, even though the release was installed earlier.
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --version 1.20.3 \
  --reuse-values \
  --set hubble.ui.enabled=true \
  --wait --timeout 3m

step "Port-forwarding Hubble UI on :12000"
kubectl -n kube-system port-forward svc/hubble-ui 12000:80 \
  > /tmp/hubble-ui-port-forward.log 2>&1 &
echo $! > /tmp/hubble-ui-port-forward.pid

ok "Hubble UI ready at http://localhost:12000"
color_green ""
color_green "To stop: kill \$(cat /tmp/hubble-ui-port-forward.pid)"
color_green "To disable in chart: helm upgrade cilium cilium/cilium -n kube-system \\"
color_green "                       --reuse-values --set hubble.ui.enabled=false"
