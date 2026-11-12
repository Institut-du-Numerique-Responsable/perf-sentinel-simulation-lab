#!/usr/bin/env bash
# Shared k3d helpers sourced by scripts/seed-services.sh and
# scripts/bootstrap.sh. No top-level side effects, only function
# definitions, so the file is safe to source more than once.

# verify_k3d_image_on_all_nodes <cluster> <image>
#
# Confirms that <image> is loaded into containerd on every k3d
# worker node (server + agent roles, loadbalancer excluded) of
# <cluster>. Prints diagnostic context to stdout when the check
# fails (either the names of nodes still missing the image, or a
# message identifying that no nodes were enumerable at all) and
# returns 1. Returns 0 only when at least one node was inspected
# and all of them have the image.
#
# Image matching uses fixed-string substring grep, which is robust
# to containerd's prefix variations (e.g. docker.io/library/...)
# and avoids regex injection on caller-supplied image names.
verify_k3d_image_on_all_nodes() {
  local cluster="$1" image="$2" node missing=() checked=0 seen attempt
  while read -r node; do
    [ -z "${node}" ] && continue
    checked=$((checked + 1))
    # The probe is retried because the probe itself is flaky on a loaded CI
    # runner, not only the import: `docker exec` can fail transiently while
    # the image is there. A single shot reported a different node missing on
    # each of two import attempts while k3d logged "Successfully imported"
    # for all three nodes both times.
    seen=""
    for attempt in 1 2 3; do
      if docker exec "${node}" ctr -n k8s.io images list -q 2>/dev/null \
          | grep -qF "${image}"; then
        seen=1
        break
      fi
      if [ "${attempt}" -lt 3 ]; then sleep 2; fi
    done
    [ -n "${seen}" ] || missing+=("${node}")
  done < <(k3d node list --no-headers 2>/dev/null \
            | awk -v c="${cluster}" '$2 ~ /^(server|agent)$/ && $3 == c {print $1}')
  if [ "${checked}" -eq 0 ]; then
    # Either no cluster, or `k3d node list` failed, or `docker exec`
    # cannot reach the daemon. The caller should treat this as an
    # environment issue, not a missing-image one.
    echo "no k3d worker node enumerable for cluster ${cluster}"
    return 1
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}

# reclaim_local_docker_image <image>
#
# Drops the host Docker copy of <image> once it has been imported into
# the k3d node containerd. Pods pull from containerd, so the Docker-side
# image is dead weight afterwards. Removing it keeps the single CI node
# from hitting disk-pressure eviction while seeding all 11 multistack
# services in sequence (the cumulative build + `k3d image import` layers
# triggered a node-wide eviction storm in validate-multistack). The build
# layer cache is left intact. Best-effort: never fails the caller.
reclaim_local_docker_image() {
  local image="$1"
  [ -n "${image}" ] || return 0
  docker image rm "${image}" >/dev/null 2>&1 || true
}

# deploy_rebuilt <namespace> <deployment> <helm command...>
#
# Runs the helm command, then restarts <deployment> if it already existed.
# Seed tags are fixed (svc:sN), so upgrading onto a rebuilt image changes no
# pod spec field and the old pod would keep serving the previous build.
deploy_rebuilt() {
  local ns="$1" deploy="$2" existed=""
  shift 2
  kubectl -n "${ns}" get deployment "${deploy}" >/dev/null 2>&1 && existed=1
  "$@" || return
  [ -z "${existed}" ] && return 0
  kubectl -n "${ns}" rollout restart deployment "${deploy}" >/dev/null &&
    kubectl -n "${ns}" rollout status deployment "${deploy}" --timeout=300s >/dev/null
}
