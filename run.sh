#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

KEEP_MAX_IMAGES=${KEEP_MAX_IMAGES:-5}
ENABLE_IMAGE_CLEANUP=${ENABLE_IMAGE_CLEANUP:-1}
ENABLE_DOCKER_CACHE_CLEANUP=${ENABLE_DOCKER_CACHE_CLEANUP:-1}
ENABLE_LOCAL_CACHE_CLEANUP=${ENABLE_LOCAL_CACHE_CLEANUP:-0}

if [ "${ENABLE_IMAGE_CLEANUP}" = "1" ]; then
  bash "${SCRIPT_DIR}/clean.sh" "${KEEP_MAX_IMAGES}"
fi

if [ "${ENABLE_DOCKER_CACHE_CLEANUP}" = "1" ]; then
  bash "${SCRIPT_DIR}/clear-docker-cache.sh"
fi

if [ "${ENABLE_LOCAL_CACHE_CLEANUP}" = "1" ]; then
  bash "${SCRIPT_DIR}/clear-runner-local-cache.sh"
fi
