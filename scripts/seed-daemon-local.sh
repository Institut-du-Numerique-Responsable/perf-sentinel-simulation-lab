#!/usr/bin/env bash
# Build a perf-sentinel daemon image from a local source checkout, import it
# into the k3d cluster, and pin the daemon manifest to it (working-tree edit,
# NOT committed). Pre-release validation flow: the maintainer replaces the
# pin with the GHCR digest once the release image exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
CLUSTER_NAME="${CLUSTER_NAME:-perf-sentinel-lab}"
MANIFEST="${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml"

[ -d "${PERF_SENTINEL_REPO_PATH}" ] || { echo "error: no perf-sentinel checkout at ${PERF_SENTINEL_REPO_PATH}" >&2; exit 1; }

VERSION="$(grep -m1 '^version' "${PERF_SENTINEL_REPO_PATH}/Cargo.toml" | sed 's/.*"\(.*\)"/\1/')"
REV="${PERF_SENTINEL_REV:-HEAD}"
SHA="$(git -C "${PERF_SENTINEL_REPO_PATH}" rev-parse --short "${REV}")"
# The tag carries the SHA, not just the version: a release branch often keeps
# the previous version in Cargo.toml until tag time, so two builds of DIFFERENT
# revisions would otherwise collide on one tag and silently A/B against itself.
TAG="perf-sentinel:${VERSION}-${SHA}"

if ! git -C "${PERF_SENTINEL_REPO_PATH}" diff --quiet "${REV}" -- crates Cargo.toml Cargo.lock 2>/dev/null; then
  echo "warning: working tree differs from ${REV}; the image is built from the COMMITTED revision" >&2
fi

# Build from a `git archive` context, not from the checkout directory: the
# product repo carries a .dockerignore scoped to its own release Dockerfile
# (build/ only), which empties the context this multistage build compiles from,
# and its target/ directory is several GB of build cache Docker would upload.
CTX_DIR="$(mktemp -d)"
trap 'rm -rf "${CTX_DIR}"' EXIT
git -C "${PERF_SENTINEL_REPO_PATH}" archive "${REV}" | tar -x -C "${CTX_DIR}"
rm -f "${CTX_DIR}/.dockerignore"

echo "==> building ${TAG} from ${PERF_SENTINEL_REPO_PATH}@${SHA} (musl static, FROM scratch)"
# DAEMON_BUILD_JOBS caps rustc parallelism inside the build: a 24 GiB host running
# the k3d nodes beside it dies on the default of one job per CPU.
docker build -q ${DAEMON_BUILD_JOBS:+--build-arg "CARGO_BUILD_JOBS=${DAEMON_BUILD_JOBS}"} \
  -f "${REPO_ROOT}/tools/daemon-image/Dockerfile" -t "${TAG}" "${CTX_DIR}"

echo "==> importing ${TAG} into k3d cluster ${CLUSTER_NAME}"
k3d image import "${TAG}" -c "${CLUSTER_NAME}"

echo "==> pinning ${MANIFEST} to ${TAG} (uncommitted working-tree edit)"
python3 - "${MANIFEST}" "${TAG}" <<'PY'
import re
import sys

path, tag = sys.argv[1], sys.argv[2]
src = open(path).read()
out, n = re.subn(
    # Either the committed GHCR digest pin, or a local pin left by a previous
    # run: re-pinning to a second revision is the whole point of an A/B.
    r"image: (?:ghcr\.io/institut-du-numerique-responsable/perf-sentinel@sha256:[0-9a-f]+"
    r"|perf-sentinel:[0-9A-Za-z._-]+)(\s*#.*)?",
    f"image: {tag}  # local pre-release build, replace with the GHCR digest at release",
    src,
)
if n == 0 and f"image: {tag}" not in src:
    sys.exit("error: could not find the daemon image pin to replace")
if "imagePullPolicy" not in out:
    out = out.replace(
        f"image: {tag}  # local pre-release build, replace with the GHCR digest at release",
        f"image: {tag}  # local pre-release build, replace with the GHCR digest at release\n          imagePullPolicy: Never",
    )
open(path, "w").write(out)
PY

echo "==> applying and rolling the daemon"
kubectl apply -f "${MANIFEST}" >/dev/null
kubectl -n observability rollout status deploy/perf-sentinel-daemon --timeout=180s

echo "==> done. The manifest now carries an uncommitted local pin:"
git -C "${REPO_ROOT}" diff --stat -- manifests/perf-sentinel-daemon.yaml || true
