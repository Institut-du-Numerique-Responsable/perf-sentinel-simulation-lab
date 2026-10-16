#!/usr/bin/env bash
# Build a PerfSentinelHub image from a local source checkout, import it into the
# k3d cluster, and pin the hub manifest to it (working-tree edit, NOT committed).
#
# Mirrors scripts/seed-daemon-local.sh. One difference on purpose: no lab-owned
# Dockerfile under tools/. The daemon needed one because the product's release
# Dockerfile expects a pre-built build/ directory its .dockerignore does not
# ship; the Hub's own Dockerfile is already a source-to-binary multistage build,
# so building it directly also exercises the real release recipe.
#
# Like the daemon, the committed manifest pins a published image by digest, so
# this script is the pre-release path: it overrides that pin with a local build
# until the next `git checkout -- manifests/perf-sentinel-hub.yaml`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HUB_REPO_PATH="${PERF_SENTINEL_HUB_REPO_PATH:-${HOME}/RiderProjects/PerfSentinelHub}"
CLUSTER_NAME="${CLUSTER_NAME:-perf-sentinel-lab}"
MANIFEST="${REPO_ROOT}/manifests/perf-sentinel-hub.yaml"
SECRET_FILE="${REPO_ROOT}/.perf-sentinel-hub-import-key"

[ -d "${HUB_REPO_PATH}" ] || { echo "error: no PerfSentinelHub checkout at ${HUB_REPO_PATH}" >&2; exit 1; }

VERSION="$(sed -n 's|.*<Version>\(.*\)</Version>.*|\1|p' "${HUB_REPO_PATH}/PerfSentinelHub/PerfSentinelHub.csproj" | head -1)"
[ -n "${VERSION}" ] || { echo "error: could not read <Version> from PerfSentinelHub.csproj" >&2; exit 1; }
REV="${PERF_SENTINEL_HUB_REV:-HEAD}"
SHA="$(git -C "${HUB_REPO_PATH}" rev-parse --short "${REV}")"
# The tag carries the SHA for the same reason the daemon's does: a release
# branch keeps the previous version in the csproj until tag time, so two builds
# of different revisions would otherwise collide on one tag.
TAG="perf-sentinel-hub:${VERSION}-${SHA}"

if ! git -C "${HUB_REPO_PATH}" diff --quiet "${REV}" -- PerfSentinelHub 2>/dev/null; then
  echo "warning: working tree differs from ${REV}; the image is built from the COMMITTED revision" >&2
fi

# Build from a `git archive` context so the image matches the committed
# revision and no local build output (bin/, obj/) inflates the context.
CTX_DIR="$(mktemp -d)"
trap 'rm -rf "${CTX_DIR}"' EXIT
git -C "${HUB_REPO_PATH}" archive "${REV}" | tar -x -C "${CTX_DIR}"

# The Dockerfile pins a published engine by digest. Before that engine is
# published, HUB_ENGINE_IMAGE (a seed-daemon-local tag, which ships /perf-sentinel
# like the release image) stands in for it, and the tag says so.
if [ -n "${HUB_ENGINE_IMAGE:-}" ]; then
  perl -pi -e 's|^FROM \S+ AS engine$|FROM $ENV{HUB_ENGINE_IMAGE} AS engine|' "${CTX_DIR}/Dockerfile"
  grep -q "^FROM ${HUB_ENGINE_IMAGE} AS engine$" "${CTX_DIR}/Dockerfile" \
    || { echo "error: no 'FROM ... AS engine' line to replace in the Hub Dockerfile" >&2; exit 1; }
  TAG="${TAG}-engine-${HUB_ENGINE_IMAGE##*:}"
fi

echo "==> building ${TAG} from ${HUB_REPO_PATH}@${SHA} (NativeAOT, chiselled)"
docker build -q -f "${CTX_DIR}/Dockerfile" --build-arg "VERSION=${VERSION}" -t "${TAG}" "${CTX_DIR}"

echo "==> importing ${TAG} into k3d cluster ${CLUSTER_NAME}"
k3d image import "${TAG}" -c "${CLUSTER_NAME}"

# The import key authenticates the daemon's push. One value, mounted two ways:
# an env var on the Hub, a file on the daemon. Generated once and kept out of
# git so re-running this script does not invalidate a live daemon's key.
if [ ! -f "${SECRET_FILE}" ]; then
  echo "==> generating the hub import key (${SECRET_FILE}, gitignored)"
  # HubOptionsValidator requires at least 32 characters.
  openssl rand -hex 32 > "${SECRET_FILE}"
  chmod 600 "${SECRET_FILE}"
fi

echo "==> applying the import-key Secret to observability"
kubectl -n observability create secret generic perf-sentinel-hub-import-key \
  --from-file=import-key="${SECRET_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> pinning ${MANIFEST} to ${TAG} (uncommitted working-tree edit)"
python3 - "${MANIFEST}" "${TAG}" <<'PY'
import re
import sys

path, tag = sys.argv[1], sys.argv[2]
src = open(path).read()
out, n = re.subn(
    # Either the committed published digest pin or a local pin left by a
    # previous run.
    r"image: (?:ghcr\.io/institut-du-numerique-responsable/)?perf-sentinel-hub[:@][0-9A-Za-z._:-]+(\s*#.*)?",
    f"image: {tag}  # local build, overrides the committed published pin",
    src,
)
if n == 0 and f"image: {tag}" not in src:
    sys.exit("error: could not find the hub image pin to replace")
# The committed manifest already carries an imagePullPolicy. Replace it rather
# than adding a second one: a duplicate YAML key is last-wins, so appending
# would silently leave IfNotPresent in force and defeat the local pin.
out = re.sub(r"imagePullPolicy: \w+", "imagePullPolicy: Never", out, count=1)
open(path, "w").write(out)
PY

# The Hub manifest reads the daemon's read key from this Secret, and the
# reference is not optional, so a cluster bootstrapped before the incident
# wiring landed would stall in CreateContainerConfigError with nothing saying
# why. scripts/bootstrap.sh creates it.
kubectl -n observability get secret perf-sentinel-api-keys >/dev/null 2>&1 \
  || { echo "error: no perf-sentinel-api-keys Secret in observability. This cluster predates the incident wiring, re-run scripts/bootstrap.sh" >&2; exit 1; }

echo "==> applying and rolling the hub"
kubectl apply -f "${MANIFEST}" >/dev/null
kubectl -n observability rollout status deploy/perf-sentinel-hub --timeout=180s

# Turn the daemon's push export on. It ships disabled because the daemon EXITS
# at startup when api_key_file is missing, so a committed `enabled = true`
# would CrashLoopBackOff every cluster brought up without a Hub. Now that the
# Secret exists, flipping it is safe. Another uncommitted working-tree edit,
# same as the image pin above.
DAEMON_MANIFEST="${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml"
if grep -q '^    enabled = false' "${DAEMON_MANIFEST}"; then
  echo "==> enabling [daemon.hub_export] in ${DAEMON_MANIFEST} (uncommitted)"
  python3 - "${DAEMON_MANIFEST}" <<'PY2'
import re, sys
path = sys.argv[1]
src = open(path).read()
# Only the flag inside [daemon.hub_export]; other sections have their own.
out, n = re.subn(r"(\[daemon\.hub_export\]\n    enabled = )false", r"\1true", src)
if n != 1:
    sys.exit(f"error: expected exactly one hub_export enabled flag, rewrote {n}")
open(path, "w").write(out)
PY2
  kubectl apply -f "${DAEMON_MANIFEST}" >/dev/null
  # The ConfigMap is mounted by subPath, which does not refresh in place.
  kubectl -n observability rollout restart deploy/perf-sentinel-daemon >/dev/null
  kubectl -n observability rollout status deploy/perf-sentinel-daemon --timeout=180s
fi

echo "==> done. The manifest now carries an uncommitted local pin:"
git -C "${REPO_ROOT}" diff --stat -- manifests/perf-sentinel-hub.yaml || true
