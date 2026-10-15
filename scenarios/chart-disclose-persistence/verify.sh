#!/usr/bin/env bash
# chart-disclose-persistence: prove that the upstream Helm chart's
# StatefulSet + persistence mode actually wires the public-disclosure
# archive to durable storage, that the archive survives a pod reschedule,
# and that the persisted file is a real `disclose` input.
#
# This closes a gap no other scenario covers:
#   - `disclose` / `disclose-temporal` are hermetic CLI checks against
#     committed NDJSON fixtures. They never touch the chart or a cluster.
#   - `chart-prometheusrule-pdb` is the only scenario that renders/installs
#     the real chart (charts/perf-sentinel/ in the perf-sentinel repo), but
#     it locks Phase A only (PrometheusRule + PodDisruptionBudget), not
#     persistence.
#   - `daemon-ack-workflow` proves PVC-backed persistence survives a
#     rollout, but against the lab's own hand-written manifest
#     (manifests/perf-sentinel-daemon.yaml), never through the chart's
#     StatefulSet template or its configmap.yaml auto-injection of
#     [daemon.ack] storage_path / [daemon.archive] path.
#
# So today the chart's render-time guards are unit-tested (the product
# repo's scripts/test/chart-render-guards-test.sh) and StatefulSet+
# persistence is schema-validated (helm-ci.yml template-matrix), but nobody
# installs it and proves the archive comes back after a restart. Chart
# 0.2.57 shipped exactly that class of bug once already (PVC mounted,
# nothing pointed at it, archive silently inert), so this is the live
# regression net for it.
#
# The daemon image is FROM scratch (no shell, no tar), so nothing execs into
# the perf-sentinel pod. File inspection goes through a throwaway busybox
# pod mounting the same PVC, which -- the PVC being ReadWriteOnce --
# requires scaling the StatefulSet to 0 first (same constraint
# daemon-sigterm-drain works around).
#
# Sequence:
#   1. helm install (workload.kind=StatefulSet, persistence.enabled=true)
#      --wait, from the chart source CHART_SOURCE resolves to, then assert
#      the running pod is on the image the chart's own appVersion selects.
#   2. Live-check the rendered ConfigMap actually carries [daemon.ack]
#      storage_path and [daemon.archive] path under the PVC mount.
#   3. Port-forward, inject a real N+1 fixture (shared with
#      daemon-sigterm-drain), wait for the trace to leave the window.
#   4. Scale to 0 and read the archive through a busybox reader: >= 1 window.
#      Scaling to 0 is load-bearing, not just PVC hygiene: the archive
#      writer buffers into a BufWriter and only flushes on rotation (100 MB)
#      or the graceful SIGTERM drain, so the scale-down is what puts the
#      line on disk.
#   5. Scale back to 1 (ordinal 0 reattaches the same PVC) and confirm
#      /health recovers.
#   6. Scale to 0 again and re-read: byte-identical to step 4.
#   7. Feed the post-restart archive to `disclose` and assert it aggregated
#      at least one real window (runtime+fallback window count >= 1) and
#      carried the injected N+1 through (anti_patterns_detected_count >= 1).
#
# Chart source, CHART_SOURCE:
#   auto  (default) local working-tree chart when its version is NEWER than the
#         newest published one (a release candidate: this is the pre-tag gate
#         the lab exists for), otherwise the newest published OCI chart.
#   oci   force the newest published chart from the OCI registry.
#   local force the working-tree chart at PERF_SENTINEL_CHART, else
#         ${PERF_SENTINEL_REPO_PATH:-$HOME/RustroverProjects/perf-sentinel}/charts/perf-sentinel.
# CHART_VERSION pins an explicit version and skips resolution.
#
# In `oci` mode the scenario needs no perf-sentinel checkout at all, which is
# what lets it run somewhere the product source is absent. Either way the
# resolved version is passed to helm as an explicit --version: the lab requires
# that on every helm install (docs/SCENARIOS.md, "Supply chain pinning").
#
# The daemon image is NOT overridden: the chart's own appVersion picks it, so
# the run exercises the chart/daemon pairing a real user gets.

set -uo pipefail

SCENARIO="chart-disclose-persistence"
NS="${SCENARIO}"
RELEASE="cdp"
STS_NAME="${SCENARIO}"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-$HOME/RustroverProjects/perf-sentinel}"
LOCAL_CHART="${PERF_SENTINEL_CHART:-${PERF_SENTINEL_REPO_PATH}/charts/perf-sentinel}"
CHART_SOURCE="${CHART_SOURCE:-auto}"
OCI_CHART="${OCI_CHART:-oci://ghcr.io/institut-du-numerique-responsable/charts/perf-sentinel}"
GHCR_CHART_PATH="${GHCR_CHART_PATH:-institut-du-numerique-responsable/charts/perf-sentinel}"
FIXTURE="${REPO_ROOT}/scenarios/daemon-sigterm-drain/fixtures/n-plus-one-positive.pb"
ORG_CONFIG="${SCRIPT_DIR}/fixtures/org-config.toml"

# Purge both the scratch dir and any previous report: `die` prints ${REPORT}
# and must never surface a prior run's verdict table as if it were this one's.
rm -rf "${TMP_DIR}"
rm -f "${REPORT}"
mkdir -p "${TMP_DIR}"

LOCAL_PORT="${LOCAL_PORT:-14418}"
PVC_UTIL_IMAGE="${PVC_UTIL_IMAGE:-busybox:1.37}"
ARCHIVE_WAIT_TIMEOUT="${ARCHIVE_WAIT_TIMEOUT:-90}"
PROM_URL="${PROM_URL:-http://localhost:9090}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record()      { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS - $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL - $2"; }

# Git Bash rewrites anything that looks like a POSIX path in a docker argument,
# so `-v /tmp/x:/data` arrives mangled. Suppressing that with MSYS_NO_PATHCONV
# is only half the job: the untranslated `/tmp/x` then resolves inside Docker's
# own VM, which silently mounts an empty directory instead of failing. The
# source therefore has to be converted to a real Windows path as well.
# On Linux and macOS both are no-ops: the prefix is empty and the path is used
# verbatim.
IS_MSYS="no"
DOCKER_ENV_PREFIX=()
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_MSYS="yes"; DOCKER_ENV_PREFIX=(env MSYS_NO_PATHCONV=1) ;;
esac

# Host path to hand to `docker run -v`.
docker_mount_path() {
  if [ "${IS_MSYS}" = "yes" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

PF_PID=""
pf_stop() { [ -n "${PF_PID}" ] && kill "${PF_PID}" >/dev/null 2>&1; PF_PID=""; }

cleanup() {
  pf_stop
  if [ "${KEEP_NAMESPACE:-no}" = "yes" ]; then
    return
  fi
  helm uninstall "${RELEASE}" -n "${NS}" >/dev/null 2>&1
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

pf_start() {
  pf_stop
  kubectl -n "${NS}" port-forward "pod/${STS_NAME}-0" "${LOCAL_PORT}:4318" >"${TMP_DIR}/pf.log" 2>&1 &
  PF_PID=$!
  local i
  for i in $(seq 1 30); do
    curl -fsS "http://localhost:${LOCAL_PORT}/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Scale the StatefulSet and report whether the wait actually succeeded, so a
# slow reschedule is attributed to the cluster instead of surfacing later as
# a bogus "archive empty" persistence failure.
scale_to() {
  kubectl -n "${NS}" scale statefulset/"${STS_NAME}" --replicas="$1" >/dev/null 2>&1 || return 1
  if [ "$1" -eq 0 ]; then
    kubectl -n "${NS}" wait --for=delete "pod/${STS_NAME}-0" --timeout=120s >/dev/null 2>&1 || return 1
  else
    kubectl -n "${NS}" rollout status statefulset/"${STS_NAME}" --timeout=120s >/dev/null 2>&1 || return 1
  fi
  return 0
}

# Read the archive on the PVC through a throwaway busybox pod. RWO, so this
# only works with the StatefulSet scaled to 0.
#
# Never calls `die`: it runs inside the main shell (not a command
# substitution) and sets globals, because a `die` inside `$( )` would print
# its diagnostic into the captured value instead of the terminal.
#   ARCHIVE_STATUS : ok | nopvc | readfail
#   ARCHIVE_LINES  : window count, only meaningful when status is ok
# The __ARCHIVE_OK__ sentinel distinguishes a genuinely empty archive from a
# swallowed kubectl failure, which would otherwise both read as zero lines
# and get blamed on the chart (same guard as daemon-sigterm-drain).
ARCHIVE_STATUS=""
ARCHIVE_LINES=0
read_archive() {
  local out_file="$1" pvc out rc
  ARCHIVE_STATUS="ok"
  ARCHIVE_LINES=0
  : > "${out_file}"

  pvc="$(kubectl -n "${NS}" get pvc -o name 2>/dev/null | grep "data-${STS_NAME}" | head -1)"
  if [ -z "${pvc}" ]; then
    ARCHIVE_STATUS="nopvc"
    return 0
  fi
  pvc="${pvc#persistentvolumeclaim/}"

  kubectl -n "${NS}" delete pod "${SCENARIO}-reader" --grace-period=1 --ignore-not-found --wait=true >/dev/null 2>&1
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: ${SCENARIO}-reader, namespace: ${NS}, labels: { app.kubernetes.io/part-of: perf-sentinel-lab } }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: reader
      image: ${PVC_UTIL_IMAGE}
      command: ["sh","-c","sleep 120"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [ { name: data, mountPath: /data, readOnly: true } ]
  volumes: [ { name: data, persistentVolumeClaim: { claimName: ${pvc}, readOnly: true } } ]
EOF
  if ! kubectl -n "${NS}" wait --for=condition=Ready pod/"${SCENARIO}-reader" --timeout=90s >/dev/null 2>&1; then
    kubectl -n "${NS}" delete pod "${SCENARIO}-reader" --grace-period=1 --wait=false >/dev/null 2>&1
    ARCHIVE_STATUS="readfail"
    return 0
  fi

  # The daily rollups (0.29.0+) sit beside the archive, one file per month.
  out="$(kubectl -n "${NS}" exec "${SCENARIO}-reader" -- sh -c \
    'if [ -f /data/archive.ndjson ]; then cat /data/archive.ndjson; fi; echo __ARCHIVE_OK__; for f in /data/archive-daily-*.ndjson; do if [ -f "$f" ]; then cat "$f"; fi; done; echo __ROLLUPS_OK__' 2>/dev/null)"
  rc=$?
  kubectl -n "${NS}" delete pod "${SCENARIO}-reader" --grace-period=1 --wait=true >/dev/null 2>&1
  if [ "${rc}" -ne 0 ] || [ "$(printf '%s\n' "${out}" | tail -1)" != "__ROLLUPS_OK__" ]; then
    ARCHIVE_STATUS="readfail"
    return 0
  fi

  printf '%s\n' "${out}" | sed '/^__ARCHIVE_OK__$/,$d' > "${out_file}"
  printf '%s\n' "${out}" | sed '1,/^__ARCHIVE_OK__$/d;$d' > "${out_file%.ndjson}-rollups.ndjson"
  ARCHIVE_LINES="$(grep -c . "${out_file}" 2>/dev/null)"
  case "${ARCHIVE_LINES}" in ''|*[!0-9]*) ARCHIVE_LINES=0 ;; esac
  return 0
}

step "0. Preflight"
command -v helm    >/dev/null 2>&1 || die "helm not on PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not on PATH"
command -v docker  >/dev/null 2>&1 || die "docker CLI required to run disclose against the persisted archive"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"
command -v curl    >/dev/null 2>&1 || die "curl not on PATH"
[ -s "${FIXTURE}" ] || die "N+1 fixture missing at ${FIXTURE} (regenerate via scenarios/daemon-sigterm-drain/fixtures/generate.py)"
[ -s "${ORG_CONFIG}" ] || die "org-config fixture missing at ${ORG_CONFIG}"

# Newest published chart version, from the anonymous GHCR Registry v2 API.
# Same shape as the product's scripts/release-chart.sh check_ghcr_image().
#
# `?n=1000` matters: the default page size truncates at ~50 tags and this
# repository already carries 86, so an unpaginated read would stop inside the
# retired 0.2.x line and resolve "newest" to 0.2.43. A `Link: rel=next` on the
# response means the page was still capped, and silently installing an ancient
# chart is worse than failing, so that case returns empty and the caller dies.
latest_published_chart() {
  local token body
  token="$(curl -sS --max-time 30 \
    "https://ghcr.io/token?scope=repository%3A$(printf '%s' "${GHCR_CHART_PATH}" | sed 's|/|%2F|g')%3Apull&service=ghcr.io" \
    2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  [ -n "${token}" ] || return 1
  body="$(curl -sS --max-time 30 -D "${TMP_DIR}/tags-headers.txt" \
    -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${GHCR_CHART_PATH}/tags/list?n=1000" 2>/dev/null)"
  [ -n "${body}" ] || return 1
  if grep -qi '^link:' "${TMP_DIR}/tags-headers.txt" 2>/dev/null; then
    return 1
  fi
  # Parse with python rather than tr/sed: the shell pipeline this replaced
  # stripped [ ] and " but not the closing }, so the LAST element of the tags
  # array kept a trailing brace and was dropped by the semver filter. That is
  # invisible while the array happens to end on a cosign fallback tag and
  # silently selects the previous release the day it ends on a version tag.
  printf '%s' "${body}" | python3 -c '
import json, sys
try:
    tags = json.load(sys.stdin).get("tags") or []
except Exception:
    sys.exit(1)
sem = []
for t in tags:
    parts = t.split(".")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        sem.append(tuple(int(p) for p in parts))
if not sem:
    sys.exit(1)
print("%d.%d.%d" % max(sem))
' 2>/dev/null
}

# Compare two X.Y.Z strings. Prints "newer" when $1 > $2, else "notnewer".
version_gt() {
  [ "$1" = "$2" ] && { printf 'notnewer\n'; return 0; }
  if [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]; then
    printf 'newer\n'
  else
    printf 'notnewer\n'
  fi
}

LOCAL_CHART_VERSION=""
if [ -f "${LOCAL_CHART}/Chart.yaml" ]; then
  LOCAL_CHART_VERSION="$(awk '/^version:/{print $2; exit}' "${LOCAL_CHART}/Chart.yaml" | tr -d '"'"'"'')"
fi

# CHART_VERSION genuinely skips resolution, as the docs and the die message
# below both promise: it is the escape hatch for a run that cannot reach the
# tag list at all.
PUBLISHED_VERSION=""
if [ -z "${CHART_VERSION:-}" ]; then
  case "${CHART_SOURCE}" in
    auto|oci)
      PUBLISHED_VERSION="$(latest_published_chart)"
      if [ -z "${PUBLISHED_VERSION}" ] && [ "${CHART_SOURCE}" = "oci" ]; then
        die "could not resolve the newest published chart version from ghcr.io/${GHCR_CHART_PATH} (network, or the tag list is paginated). Pin it with CHART_VERSION=X.Y.Z."
      fi
      ;;
  esac
fi

# auto: a locally-bumped chart is a release candidate, and validating it before
# the tag is the whole point of the lab. Anything else means there is no
# pending release, so test what users actually pull.
#
# There is deliberately NO silent fallback to the local chart when the registry
# cannot be reached. Doing that would let a stale checkout be installed,
# PASSed and written into the release-gate ledger as if it were the published
# chart, with the cosign leg quietly skipped on top. An unreachable registry is
# an inconclusive run, not a green one.
RESOLVED_SOURCE="${CHART_SOURCE}"
if [ "${CHART_SOURCE}" = "auto" ]; then
  if [ -n "${CHART_VERSION:-}" ]; then
    RESOLVED_SOURCE="oci"
  elif [ -z "${PUBLISHED_VERSION}" ]; then
    die "CHART_SOURCE=auto cannot decide: the newest published version could not be resolved from ghcr.io/${GHCR_CHART_PATH}. Falling back to the local chart would risk certifying a stale checkout as the published one. Fix connectivity, or choose explicitly with CHART_SOURCE=local, or pin CHART_VERSION=X.Y.Z."
  elif [ -n "${LOCAL_CHART_VERSION}" ] \
    && [ "$(version_gt "${LOCAL_CHART_VERSION}" "${PUBLISHED_VERSION}")" = "newer" ]; then
    RESOLVED_SOURCE="local"
  else
    RESOLVED_SOURCE="oci"
  fi
fi

case "${RESOLVED_SOURCE}" in
  local)
    [ -f "${LOCAL_CHART}/Chart.yaml" ] || die "chart not found at ${LOCAL_CHART} (set PERF_SENTINEL_CHART or PERF_SENTINEL_REPO_PATH, or use CHART_SOURCE=oci)"
    CHART_REF="${LOCAL_CHART}"
    # helm resolves a directory chart by path and ignores --version entirely,
    # so CHART_PIN has to be whatever Chart.yaml actually declares. Honouring a
    # differing CHART_VERSION here would make the report name a version that
    # was never installed, which is exactly what the ledger must not record.
    if [ -n "${CHART_VERSION:-}" ] && [ "${CHART_VERSION}" != "${LOCAL_CHART_VERSION}" ]; then
      die "CHART_VERSION=${CHART_VERSION} cannot be honoured against the local chart at ${LOCAL_CHART}, which is ${LOCAL_CHART_VERSION}: helm ignores --version for a directory. Check out the wanted version, or use CHART_SOURCE=oci."
    fi
    CHART_PIN="${LOCAL_CHART_VERSION}"
    CHART_ORIGIN="local working tree ${LOCAL_CHART}"
    ;;
  oci)
    CHART_REF="${OCI_CHART}"
    CHART_PIN="${CHART_VERSION:-${PUBLISHED_VERSION}}"
    CHART_ORIGIN="published ${OCI_CHART}"
    ;;
  *)
    die "CHART_SOURCE must be auto, oci or local (got '${CHART_SOURCE}')"
    ;;
esac
[ -n "${CHART_PIN}" ] || die "could not determine a chart version to pin"

# The chart's appVersion picks the daemon image by default, so read it from the
# resolved chart rather than overriding it: the point is to exercise the
# pairing a real user gets. `helm show` works identically on a path and an
# oci:// ref. Parsed with python because the values file is YAML and several
# blocks carry a two-space `repository:` key. Matching the first one would bind
# to whichever block happens to sort first.
CHART_META="$(helm show chart "${CHART_REF}" --version "${CHART_PIN}" 2>"${TMP_DIR}/show-chart.log")"
[ -n "${CHART_META}" ] || { cat "${TMP_DIR}/show-chart.log"; die "helm show chart failed for ${CHART_REF} --version ${CHART_PIN}"; }
APP_VERSION="$(printf '%s\n' "${CHART_META}" | awk '/^appVersion:/{print $2; exit}' | tr -d '"'"'"'')"
[ -n "${APP_VERSION}" ] || die "resolved chart ${CHART_PIN} declares no appVersion"

helm show values "${CHART_REF}" --version "${CHART_PIN}" >"${TMP_DIR}/chart-values.yaml" 2>/dev/null
# Mirrors _helpers.tpl: image is `repository:(tag | default appVersion)`.
CHART_IMAGE="$(python3 -c '
import re, sys
app = sys.argv[2]
repo = tag = None
block = False
for line in open(sys.argv[1], encoding="utf-8"):
    if re.match(r"^image:\s*$", line):
        block = True
        continue
    if block:
        if re.match(r"^\S", line):
            break
        m = re.match(r"^  repository:\s*(\S+)", line)
        if m:
            repo = m.group(1).strip("\"'"'"'")
        m = re.match(r"^  tag:\s*(.*)$", line)
        if m:
            tag = m.group(1).strip().strip("\"'"'"'")
if not repo:
    sys.exit(1)
print("%s:%s" % (repo, tag or app))
' "${TMP_DIR}/chart-values.yaml" "${APP_VERSION}" 2>/dev/null)"
[ -n "${CHART_IMAGE}" ] || die "could not read image.repository from the resolved chart values (${TMP_DIR}/chart-values.yaml)"

# DAEMON_IMAGE overrides what the chart would pull. Needed for a
# release-candidate run: a locally bumped chart names an appVersion whose image
# is only pushed at tag time, so without an override the pod would sit in
# ImagePullBackOff. Build and import one first with scripts/seed-daemon-local.sh.
IMAGE="${DAEMON_IMAGE:-${CHART_IMAGE}}"
IMAGE_OVERRIDDEN="no"
[ "${IMAGE}" != "${CHART_IMAGE}" ] && IMAGE_OVERRIDDEN="yes"
ok "chart ${CHART_ORIGIN}, version ${CHART_PIN}, appVersion ${APP_VERSION} -> image ${IMAGE}$([ "${IMAGE_OVERRIDDEN}" = yes ] && printf ' (DAEMON_IMAGE override, chart default %s)' "${CHART_IMAGE}")"
[ "${RESOLVED_SOURCE}" = "oci" ] && [ -n "${LOCAL_CHART_VERSION}" ] \
  && ok "local working tree is ${LOCAL_CHART_VERSION}, not ahead of the published ${PUBLISHED_VERSION}, so testing the published chart"

# k3d nodes pull into the node container's containerd, which never populates
# the host docker image store, so a working cluster install says nothing
# about step 7's `docker run`. Resolve it up front (same guard as
# scenarios/disclose/verify.sh) instead of failing the roundtrip later.
DOCKER_IMAGE_READY="yes"
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  if ! docker pull "${IMAGE}" >"${TMP_DIR}/pull.log" 2>&1; then
    DOCKER_IMAGE_READY="no"
    color_red "    warning: ${IMAGE} not in the host docker store and pull failed; step 7 will SKIP"
  fi
fi

if kubectl get namespace "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
  kubectl wait --for=delete namespace/"${NS}" --timeout=90s >/dev/null 2>&1
fi
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 \
  || die "could not create namespace ${NS}"
kubectl label ns "${NS}" app.kubernetes.io/part-of=perf-sentinel-lab \
  pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null 2>&1
kubectl apply -f "${REPO_ROOT}/manifests/network-policies.yaml" >/dev/null

step "1. helm install (workload.kind=StatefulSet, persistence.enabled=true) --wait"
# --version is explicit even for the local path: the lab requires it on every
# helm install (docs/SCENARIOS.md, "Supply chain pinning"). helm ignores it for
# a directory chart, which is why CHART_PIN is forced to Chart.yaml's own
# version above so the flag can never disagree with what gets installed.
HELM_IMAGE_ARGS=()
if [ "${IMAGE_OVERRIDDEN}" = "yes" ]; then
  HELM_IMAGE_ARGS=(--set "image.repository=${IMAGE%:*}" --set "image.tag=${IMAGE##*:}")
fi
if helm install "${RELEASE}" "${CHART_REF}" --version "${CHART_PIN}" -n "${NS}" \
  --set "fullnameOverride=${STS_NAME}" \
  --set "workload.kind=StatefulSet" \
  --set "workload.replicas=1" \
  --set "workload.statefulset.persistence.enabled=true" \
  --set "workload.statefulset.persistence.size=1Gi" \
  --set "serviceMonitor.enabled=true" \
  ${HELM_IMAGE_ARGS[@]+"${HELM_IMAGE_ARGS[@]}"} \
  --wait --timeout 180s > "${TMP_DIR}/install.log" 2>&1; then
  assert_pass "helm-install" "chart ${CHART_PIN} (${RESOLVED_SOURCE}) installed as StatefulSet + persistence, pod Ready"
else
  tail -20 "${TMP_DIR}/install.log"
  die "helm install failed, see ${TMP_DIR}/install.log"
fi

# Record what was actually certified. Comparing the pod's image STRING to one
# rebuilt from the same chart would be tautological (the template computes it
# the same way), so the real assertion is on the resolved digest: the pod's
# imageID must match what the registry says that tag points at right now. That
# is what catches a node still running a stale layer for a re-pushed mutable
# tag under imagePullPolicy: IfNotPresent.
RUNNING_IMAGE="$(kubectl -n "${NS}" get pod "${STS_NAME}-0" \
  -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)"
RUNNING_ID="$(kubectl -n "${NS}" get pod "${STS_NAME}-0" \
  -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null)"
REGISTRY_DIGEST="$(docker image inspect "${IMAGE}" \
  --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
  | sed -n 's/.*@\(sha256:[0-9a-f]*\)$/\1/p' | head -1)"
# An image built locally and never pushed still gets a RepoDigest, but it is its
# own config Id rather than anything a registry ever served. Comparing that to a
# pod's imageID cannot work: `k3d image import` hands the tarball to containerd,
# which computes its own id, so the two differ by construction and the leg would
# report a stale layer that does not exist. Detect the case and SKIP.
LOCAL_ID="$(docker image inspect "${IMAGE}" --format '{{.Id}}' 2>/dev/null)"
if [ -n "${REGISTRY_DIGEST}" ] && [ "sha256:${REGISTRY_DIGEST#sha256:}" = "${LOCAL_ID}" ]; then
  REGISTRY_DIGEST=""
  PROVENANCE_LOCAL="yes"
fi
if [ "${RUNNING_IMAGE}" != "${IMAGE}" ]; then
  assert_fail "chart-provenance" "pod runs ${RUNNING_IMAGE:-<unreadable>}, expected ${IMAGE}"
elif [ -z "${RUNNING_ID}" ]; then
  assert_fail "chart-provenance" "could not read imageID from pod ${STS_NAME}-0, cannot confirm which bits run"
elif [ -z "${REGISTRY_DIGEST}" ]; then
  record "chart-provenance" "SKIP - ${CHART_ORIGIN} v${CHART_PIN}, appVersion ${APP_VERSION}, pod on ${RUNNING_IMAGE} (${RUNNING_ID}); $([ "${PROVENANCE_LOCAL:-no}" = yes ] && printf 'locally built image never pushed, its RepoDigest is its own config Id and cannot be compared to a containerd imageID' || printf 'no local RepoDigest to compare against')"
  color_red "    skip: provenance not checkable on a locally built image (expected during a pre-release round)"
elif [ "${RUNNING_ID#*@}" = "${REGISTRY_DIGEST}" ]; then
  assert_pass "chart-provenance" "${CHART_ORIGIN} v${CHART_PIN}, appVersion ${APP_VERSION}, pod digest matches the registry (${REGISTRY_DIGEST})"
else
  assert_fail "chart-provenance" "pod runs ${RUNNING_ID}, but ${IMAGE} currently resolves to ${REGISTRY_DIGEST} (stale cached layer for a re-pushed tag?)"
fi

step "1b. Prometheus discovers exactly one target for the StatefulSet pod"
TARGET_OK="no"
TARGET_NOTE=""
for _ in $(seq 1 18); do
  if curl -fsS --max-time 10 "${PROM_URL}/api/v1/targets" >"${TMP_DIR}/targets.json" 2>/dev/null; then
    if TARGET_NOTE=$(python3 - "${TMP_DIR}/targets.json" "${NS}" "${STS_NAME}" <<'PY'
import json, sys
data, namespace, name = json.load(open(sys.argv[1], encoding="utf-8")), sys.argv[2], sys.argv[3]
matches = []
for target in data["data"]["activeTargets"]:
    discovered = target.get("discoveredLabels", {})
    if (discovered.get("__meta_kubernetes_namespace") == namespace and
            discovered.get("__meta_kubernetes_service_name", "").startswith(name)):
        matches.append(target)
assert len(matches) == 1, [(t.get("labels", {}).get("job"), t.get("discoveredLabels", {}).get("__meta_kubernetes_service_name")) for t in matches]
target = matches[0]
service = target["discoveredLabels"]["__meta_kubernetes_service_name"]
assert service == name, service
assert target.get("health") == "up", target.get("health")
print("job=%s service=%s health=up" % (target.get("labels", {}).get("job", "?"), service))
PY
    ); then
      TARGET_OK="yes"
      break
    fi
  fi
  sleep 5
done
if [ "${TARGET_OK}" = "yes" ]; then
  assert_pass "servicemonitor-target" "one main-Service target, no headless duplicate (${TARGET_NOTE})"
else
  assert_fail "servicemonitor-target" "Prometheus did not converge to one healthy ${STS_NAME} target; see ${TMP_DIR}/targets.json"
fi

# Parity with the documented consumer path (docs/HELM-DEPLOYMENT.md, "Software
# supply chain"): published charts are cosign-keyless-signed. Optional, like
# kubeconform/promtool in chart-prometheusrule-pdb. `helm install --verify` is
# deliberately not used, the chart ships no .prov file.
#
# Two portability details the documented one-liner does not carry:
#   - the identity regex uses [.] rather than \. because Git Bash rewrites
#     backslash escapes inside arguments, turning \. into /. and making the
#     match fail with a confusing "no matching CertificateIdentity";
#   - the signature is a Sigstore bundle attached as an OCI 1.1 referrer, not a
#     legacy sha256-<digest>.sig tag, so cosign 2.x reports "no signatures
#     found" and only 3.x verifies it. That is reported as a distinct verdict
#     rather than a flat failure, since the artifact is signed either way.
COSIGN_IDENTITY_RE='^https://github[.]com/(robintra|Institut-du-Numerique-Responsable)/perf-sentinel/[.]github/workflows/helm-release[.]yml@refs/tags/chart-v'
COSIGN_VER="$(cosign version 2>/dev/null | awk '/GitVersion/{print $2}')"
COSIGN_MAJOR="$(printf '%s' "${COSIGN_VER}" | sed -n 's/^v\{0,1\}\([0-9]\{1,\}\)\..*/\1/p')"
if [ "${RESOLVED_SOURCE}" != "oci" ]; then
  record "cosign-verify" "SKIP - local working-tree chart is unsigned by construction"
elif ! command -v cosign >/dev/null 2>&1; then
  record "cosign-verify" "SKIP - cosign not on PATH"
elif cosign verify \
  --certificate-identity-regexp "${COSIGN_IDENTITY_RE}" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/${GHCR_CHART_PATH}:${CHART_PIN}" >"${TMP_DIR}/cosign.log" 2>&1; then
  assert_pass "cosign-verify" "keyless signature valid for chart ${CHART_PIN} (cosign ${COSIGN_VER:-unknown})"
elif grep -q 'no signatures found' "${TMP_DIR}/cosign.log" 2>/dev/null \
  && [ -n "${COSIGN_MAJOR}" ] && [ "${COSIGN_MAJOR}" -lt 3 ]; then
  # Only a pre-3.x cosign earns the benefit of the doubt: it cannot read the
  # OCI 1.1 referrer bundle these charts are signed with. A 3.x cosign printing
  # the same message means the artifact genuinely carries no signature, which
  # is a supply-chain regression and must fail, not skip.
  record "cosign-verify" "SKIP - cosign ${COSIGN_VER} predates 3.x and cannot read the OCI 1.1 referrer bundle this chart is signed with"
elif grep -q 'no signatures found' "${TMP_DIR}/cosign.log" 2>/dev/null; then
  assert_fail "cosign-verify" "cosign ${COSIGN_VER:-unknown} reports NO SIGNATURE on ghcr.io/${GHCR_CHART_PATH}:${CHART_PIN}: the published chart is unsigned"
else
  tail -10 "${TMP_DIR}/cosign.log"
  assert_fail "cosign-verify" "cosign ${COSIGN_VER:-unknown} could not verify ghcr.io/${GHCR_CHART_PATH}:${CHART_PIN}"
fi

# === 2. live ConfigMap wiring check ===
# The chart's data key is `perf-sentinel.toml` (templates/configmap.yaml),
# not `config.toml`. The pod mounts it via subPath of the same name.
step "2. ConfigMap carries [daemon.ack]/[daemon.archive] pointed at the PVC mount"
CM_TOML="$(kubectl -n "${NS}" get cm "${STS_NAME}-config" -o jsonpath='{.data.perf-sentinel\.toml}' 2>/dev/null)"
if [ -z "${CM_TOML}" ]; then
  assert_fail "configmap-wiring" "ConfigMap ${STS_NAME}-config has no perf-sentinel.toml key"
elif printf '%s' "${CM_TOML}" | grep -q 'storage_path = "/var/lib/perf-sentinel/acks.jsonl"' \
  && printf '%s' "${CM_TOML}" | grep -q 'path = "/var/lib/perf-sentinel/archive.ndjson"'; then
  assert_pass "configmap-wiring" "ack storage_path and archive path both wired onto the PVC mount"
else
  printf '%s' "${CM_TOML}" | grep -E 'daemon\.(ack|archive)' -A2 || true
  assert_fail "configmap-wiring" "ack/archive paths missing or not pointed at /var/lib/perf-sentinel"
fi

step "3. Inject the N+1 fixture and wait for the trace to finalize"
INJECTED="no"
if ! pf_start; then
  assert_fail "archive-write" "port-forward to ${STS_NAME}-0 never became reachable"
else
  HTTP_INJ="$(curl -o /dev/null -s -w "%{http_code}" \
    -X POST "http://localhost:${LOCAL_PORT}/v1/traces" \
    -H "Content-Type: application/x-protobuf" \
    --data-binary "@${FIXTURE}" 2>/dev/null)"
  if [ "${HTTP_INJ}" != "200" ]; then
    assert_fail "archive-write" "N+1 injection failed, HTTP ${HTTP_INJ:-000}"
  else
    ok "injected (HTTP 200), polling /api/status until active_traces reaches 0"
    # active_traces hitting 0 only means the window was evicted for analysis.
    # The archive writer buffers and flushes on the scale-down below. This
    # poll bounds the wait, the scale to 0 in step 4 is what persists.
    DEADLINE=$(( $(date +%s) + ARCHIVE_WAIT_TIMEOUT ))
    while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
      ACTIVE="$(curl -fsS "http://localhost:${LOCAL_PORT}/api/status" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("active_traces",1))' 2>/dev/null)"
      if [ "${ACTIVE:-1}" = "0" ]; then INJECTED="yes"; break; fi
      sleep 2
    done
    if [ "${INJECTED}" = "yes" ]; then
      ok "trace left the correlation window"
    else
      assert_fail "archive-write" "trace never finalized within ${ARCHIVE_WAIT_TIMEOUT}s (active_traces stayed above 0)"
    fi
  fi
fi

step "4. Scale to 0 (graceful drain flushes the archive), read it back"
pf_stop
PRE_LINES=0
PRE_OK="no"
if [ "${INJECTED}" != "yes" ]; then
  record "archive-write" "SKIP - nothing was injected, see above"
elif ! scale_to 0; then
  assert_fail "archive-write" "StatefulSet did not scale to 0 within 120s (cluster slow, not a chart regression)"
else
  read_archive "${TMP_DIR}/pre-restart.ndjson"
  case "${ARCHIVE_STATUS}" in
    nopvc)
      assert_fail "archive-write" "no data-${STS_NAME}-0 PVC exists: the chart did not render the volumeClaimTemplate" ;;
    readfail)
      assert_fail "archive-write" "could not read the archive (reader pod or kubectl exec failed), cannot judge persistence" ;;
    ok)
      PRE_LINES="${ARCHIVE_LINES}"
      if [ "${PRE_LINES}" -ge 1 ]; then
        PRE_OK="yes"
        assert_pass "archive-write" "${PRE_LINES} window(s) archived to the PVC before restart"
      else
        assert_fail "archive-write" "archive read cleanly but is empty after the drain"
      fi ;;
  esac
fi

step "5. Scale to 1 (ordinal 0 reattaches the same PVC)"
RESTARTED="no"
ROLLUP_HORIZON=""
if [ "${PRE_OK}" != "yes" ]; then
  record "persistence" "SKIP - no pre-restart archive to compare against"
elif ! scale_to 1; then
  assert_fail "persistence" "StatefulSet did not come back within 120s"
elif ! pf_start; then
  assert_fail "persistence" "daemon unreachable after the rescale"
else
  RESTARTED="yes"
  ok "pod back, /health answers"
  # A daemon with daily rollups (0.29.0+) reloads the day the step-4 drain
  # closed and reports it. An older image has no such field, and step 8
  # then has nothing to compare.
  ROLLUP_HORIZON="$(curl -fsS "http://localhost:${LOCAL_PORT}/api/status" 2>/dev/null \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("disclosure_archive") or {}).get("days", ""))' 2>/dev/null)"
fi

step "6. Scale to 0 again, re-read the archive and compare"
if [ "${RESTARTED}" = "yes" ]; then
  pf_stop
  if ! scale_to 0; then
    assert_fail "persistence" "StatefulSet did not scale to 0 for the post-restart read"
  else
    read_archive "${TMP_DIR}/post-restart.ndjson"
    case "${ARCHIVE_STATUS}" in
      nopvc)
        assert_fail "persistence" "the data PVC disappeared across the restart" ;;
      readfail)
        assert_fail "persistence" "could not read the archive after the restart" ;;
      ok)
        # The property is "every pre-restart byte is still there", not
        # "nothing was added": the archive is append-only, and the daemon can
        # legitimately flush another window during the step-5 lifetime. So
        # compare the pre-restart bytes against the same-length prefix of the
        # post-restart file rather than requiring equality. PRE_LINES >= 1 is
        # already established, so two empty files cannot pass here.
        PRE_BYTES="$(wc -c < "${TMP_DIR}/pre-restart.ndjson" | tr -d ' ')"
        head -c "${PRE_BYTES}" "${TMP_DIR}/post-restart.ndjson" > "${TMP_DIR}/post-prefix.bin" 2>/dev/null
        if [ "${ARCHIVE_LINES}" -ge "${PRE_LINES}" ] \
          && cmp -s "${TMP_DIR}/pre-restart.ndjson" "${TMP_DIR}/post-prefix.bin"; then
          if [ "${ARCHIVE_LINES}" -gt "${PRE_LINES}" ]; then
            assert_pass "persistence" "archive survived the restart, pre-restart bytes intact as a prefix (${PRE_LINES} -> ${ARCHIVE_LINES} window(s), appended after the restart)"
          else
            assert_pass "persistence" "archive survived the restart byte-for-byte (${ARCHIVE_LINES} window(s))"
          fi
        else
          assert_fail "persistence" "pre=${PRE_LINES} post=${ARCHIVE_LINES} window(s): the pre-restart bytes are not intact at the head of the post-restart archive"
        fi ;;
    esac
  fi
  scale_to 1 >/dev/null 2>&1
fi

# === 7. feed the persisted archive to disclose ===
# Empty until step 7 measures them, so step 8 can tell "skipped" from "zero".
WINDOWS=""
PATTERNS=""
step "7. Run disclose against the restart-surviving archive"
if [ ! -s "${TMP_DIR}/post-restart.ndjson" ]; then
  record "disclose-roundtrip" "SKIP - no post-restart archive to feed disclose"
elif [ "${DOCKER_IMAGE_READY}" != "yes" ]; then
  record "disclose-roundtrip" "SKIP - ${IMAGE} unavailable to the host docker daemon"
else
  cp "${ORG_CONFIG}" "${TMP_DIR}/org-config.toml"
  TODAY="$(date -u +%Y-%m-%d)"
  FROM_DATE="$(date -u -d '-30 days' +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)"
  : > "${TMP_DIR}/disclose.log"
  # -u so the UID-65534 scratch image can write --output into the host-owned
  # bind mount (same as scenarios/disclose/verify.sh).
  # ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": bash before 4.4, which is
  # what macOS ships as /bin/bash (3.2), treats an empty array expansion as an
  # unset variable and `set -u` then kills the script outright.
  if ${DOCKER_ENV_PREFIX[@]+"${DOCKER_ENV_PREFIX[@]}"} docker run --rm -u "$(id -u):$(id -g)" \
    -v "$(docker_mount_path "${TMP_DIR}"):/data" \
    "${IMAGE}" disclose \
    --intent internal --confidentiality internal \
    --period-type custom --from "${FROM_DATE}" --to "${TODAY}" \
    --input /data/post-restart.ndjson \
    --output /data/report.json \
    --org-config /data/org-config.toml >"${TMP_DIR}/disclose.log" 2>&1; then
    # Assert the archive actually contributed. schema_version and aggregate
    # are non-optional fields of PeriodicReport, so checking their presence
    # would pass for any report the binary can emit. The window count and the
    # anti-pattern count are what tie the output to the persisted N+1.
    DISCLOSE_STATS="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
a = d.get("aggregate", {})
w = a.get("runtime_windows_count", 0) + a.get("fallback_windows_count", 0)
print(w, a.get("anti_patterns_detected_count", 0), d.get("schema_version", "?"))
' "${TMP_DIR}/report.json" 2>/dev/null)"
    if [ -z "${DISCLOSE_STATS}" ]; then
      assert_fail "disclose-roundtrip" "report.json missing or unparseable"
    else
      WINDOWS="$(printf '%s' "${DISCLOSE_STATS}" | awk '{print $1}')"
      PATTERNS="$(printf '%s' "${DISCLOSE_STATS}" | awk '{print $2}')"
      SCHEMA="$(printf '%s' "${DISCLOSE_STATS}" | awk '{print $3}')"
      if [ "${WINDOWS:-0}" -ge 1 ] && [ "${PATTERNS:-0}" -ge 1 ]; then
        assert_pass "disclose-roundtrip" "${SCHEMA}: aggregated ${WINDOWS} window(s), ${PATTERNS} anti-pattern(s) from the persisted archive"
      else
        assert_fail "disclose-roundtrip" "${SCHEMA}: aggregated ${WINDOWS} window(s) and ${PATTERNS} anti-pattern(s), expected at least 1 of each"
      fi
    fi
  else
    tail -20 "${TMP_DIR}/disclose.log"
    assert_fail "disclose-roundtrip" "disclose exited non-zero, see ${TMP_DIR}/disclose.log"
  fi
fi

# === 8. the daily rollups alone give the same figures ===
step "8. Run disclose against the daily rollups alone"
if [ -z "${ROLLUP_HORIZON}" ] && [ ! -s "${TMP_DIR}/post-restart-rollups.ndjson" ]; then
  record "disclose-rollups" "SKIP - ${IMAGE} reports no rollup horizon after the restart and wrote no rollup, it predates daily rollups"
elif [ ! -s "${TMP_DIR}/post-restart-rollups.ndjson" ]; then
  if [ -s "${TMP_DIR}/post-restart.ndjson" ]; then
    assert_fail "disclose-rollups" "no daily rollup line on the PVC after a graceful drain"
  else
    record "disclose-rollups" "SKIP - no post-restart archive was read"
  fi
elif [ -z "${WINDOWS}" ]; then
  record "disclose-rollups" "SKIP - step 7 produced no window figures to compare against"
else
  if ${DOCKER_ENV_PREFIX[@]+"${DOCKER_ENV_PREFIX[@]}"} docker run --rm -u "$(id -u):$(id -g)" \
    -v "$(docker_mount_path "${TMP_DIR}"):/data" \
    "${IMAGE}" disclose \
    --intent internal --confidentiality internal \
    --period-type custom --from "${FROM_DATE}" --to "${TODAY}" \
    --input /data/post-restart-rollups.ndjson \
    --output /data/report-rollups.json \
    --org-config /data/org-config.toml >"${TMP_DIR}/disclose-rollups.log" 2>&1; then
    ROLLUP_STATS="$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1])).get("aggregate", {})
print(a.get("runtime_windows_count", 0) + a.get("fallback_windows_count", 0), a.get("anti_patterns_detected_count", 0))
' "${TMP_DIR}/report-rollups.json" 2>/dev/null)"
    R_WINDOWS="$(printf '%s' "${ROLLUP_STATS}" | awk '{print $1}')"
    R_PATTERNS="$(printf '%s' "${ROLLUP_STATS}" | awk '{print $2}')"
    if [ "${R_WINDOWS:-x}" = "${WINDOWS}" ] && [ "${R_PATTERNS:-x}" = "${PATTERNS}" ]; then
      assert_pass "disclose-rollups" "rollups alone give ${R_WINDOWS} window(s) and ${R_PATTERNS} anti-pattern(s), as the windows do"
    else
      assert_fail "disclose-rollups" "rollups give ${R_WINDOWS:-?} window(s) and ${R_PATTERNS:-?} anti-pattern(s), windows gave ${WINDOWS} and ${PATTERNS}"
    fi
  else
    tail -20 "${TMP_DIR}/disclose-rollups.log"
    assert_fail "disclose-rollups" "disclose over the rollups exited non-zero, see ${TMP_DIR}/disclose-rollups.log"
  fi
fi

step "Summary"
{
  echo "# ${SCENARIO}"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Chart: ${CHART_ORIGIN}"
  echo "Chart version: ${CHART_PIN} (source ${RESOLVED_SOURCE}, CHART_SOURCE=${CHART_SOURCE})"
  echo "Newest published: ${PUBLISHED_VERSION:-unresolved}; local working tree: ${LOCAL_CHART_VERSION:-absent}"
  echo "Daemon image: ${IMAGE} (chart appVersion)"
  echo
  echo "## Sub-test verdicts"
  echo
} > "${REPORT}"
for entry in ${SUMMARY[@]+"${SUMMARY[@]}"}; do
  name="${entry%%|*}"
  verdict="${entry#*|}"
  printf "  %-20s %s\n" "${name}" "${verdict}"
  printf -- "- **%s**: %s\n" "${name}" "${verdict}" >> "${REPORT}"
done
{
  echo
  echo "**Verdict: $([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)**"
} >> "${REPORT}"

if [ "${FAILS}" -eq 0 ]; then
  ok "PASS, see ${REPORT}"
  exit 0
fi
color_red "    FAIL (${FAILS}), see ${REPORT}"
exit 1
