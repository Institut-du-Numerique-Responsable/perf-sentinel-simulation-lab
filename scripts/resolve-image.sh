#!/usr/bin/env bash
# Resolve the perf-sentinel container image a scenario should run against.
# Sourced, not executed: it sets IMAGE in the caller's shell.
#
#   LAB_ROOT=<repo root> . "${LAB_ROOT}/scripts/resolve-image.sh"
#
# Why this exists: eight image-based scenarios each carried their own hardcoded
# default (0.5.17, 0.5.21, 0.7.2, 0.8.13). A scenario pinned to an old tag runs
# green on every release without ever touching the version under validation, so
# the gate reported a PASS for code it had not executed. The 0.9.25 round found
# `esrs-e1-crosswalk` still asserting schema v1.3 and `intent-validator` still
# carrying a 2024 SPECpower vintage, neither of which any gate run could have
# surfaced.
#
# Resolution order:
#   1. PERF_SENTINEL_IMAGE: a full image reference, used verbatim. This is the
#      pre-release path: a locally built tag, or a digest.
#   2. PERF_SENTINEL_VERSION: a GHCR tag. Kept because every existing runbook
#      and CI workflow passes it.
#   3. manifests/perf-sentinel-daemon.yaml: the image the lab's daemon manifest
#      pins, so a scenario tracks whatever version the lab is validating. Used
#      verbatim: it may be a digest pin or a local pre-release tag left by
#      scripts/seed-daemon-local.sh, and neither can be rebuilt from a version
#      string.
#
# A scenario that genuinely needs a fixed version (a compatibility leg against
# an older binary, say) should name that version inline at its call site rather
# than defaulting the whole run to it.

if [ -n "${PERF_SENTINEL_IMAGE:-}" ]; then
  IMAGE="${PERF_SENTINEL_IMAGE}"
elif [ -n "${PERF_SENTINEL_VERSION:-}" ]; then
  IMAGE="ghcr.io/institut-du-numerique-responsable/perf-sentinel:${PERF_SENTINEL_VERSION}"
else
  IMAGE="$(awk '/^[[:space:]]*image:[[:space:]]*(ghcr\.io\/institut-du-numerique-responsable\/)?perf-sentinel[:@]/ { print $2; exit }' \
    "${LAB_ROOT:?resolve-image.sh: LAB_ROOT must be set}/manifests/perf-sentinel-daemon.yaml")"
  # Not `die`: the colour helpers are not defined yet at every call site.
  [ -n "${IMAGE}" ] || {
    printf "    error: cannot derive the perf-sentinel image from manifests/perf-sentinel-daemon.yaml\n" >&2
    exit 1
  }
fi
export IMAGE
