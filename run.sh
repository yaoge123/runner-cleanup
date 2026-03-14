#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/load-config.sh"
load_runner_cleanup_config "${SCRIPT_DIR}"

if [ "${RUNNER_CLEANUP_LOGGING_INITIALIZED:-0}" != "1" ]; then
  RUNNER_CLEANUP_LOG_DIR=${RUNNER_CLEANUP_LOG_DIR:-/var/log/runner-cleanup}
  RUNNER_CLEANUP_LOG_FILE=${RUNNER_CLEANUP_LOG_FILE:-${RUNNER_CLEANUP_LOG_DIR}/runner-cleanup.log}

  mkdir -p "${RUNNER_CLEANUP_LOG_DIR}"

  export RUNNER_CLEANUP_LOG_DIR
  export RUNNER_CLEANUP_LOG_FILE
  export RUNNER_CLEANUP_LOGGING_INITIALIZED=1

  if [ -t 1 ]; then
    exec > >(tee -a "${RUNNER_CLEANUP_LOG_FILE}") 2>&1
  else
    exec >>"${RUNNER_CLEANUP_LOG_FILE}" 2>&1
  fi
fi

runner_cleanup_finish() {
  local exit_code=$?
  printf '[%s] runner-cleanup end exit_code=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${exit_code}"
}

trap runner_cleanup_finish EXIT

printf '[%s] runner-cleanup start\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf 'config=%s\n' "${RUNNER_CLEANUP_CONFIG:-${SCRIPT_DIR}/runner-cleanup.conf or ./runner-cleanup.conf}"

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
