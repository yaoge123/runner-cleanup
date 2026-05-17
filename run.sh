#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

setup_runner_cleanup_logging() {
  local log_dir=$1
  local log_file=$2
  local log_file_dir

  mkdir -p "${log_dir}"
  log_file_dir=$(dirname -- "${log_file}")
  mkdir -p "${log_file_dir}"

  export RUNNER_CLEANUP_LOG_DIR="${log_dir}"
  export RUNNER_CLEANUP_LOG_FILE="${log_file}"
  export RUNNER_CLEANUP_LOGGING_INITIALIZED=1

  if [ -t 1 ]; then
    exec > >(tee -a "${log_file}") 2>&1
  else
    exec >>"${log_file}" 2>&1
  fi
}

runner_cleanup_finish() {
  local exit_code=$?
  printf '[%s] runner-cleanup end exit_code=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${exit_code}"
}

if [ "${RUNNER_CLEANUP_LOGGING_INITIALIZED:-0}" != "1" ] && [ -n "${RUNNER_CLEANUP_LOG_FILE:-}" ]; then
  setup_runner_cleanup_logging \
    "${RUNNER_CLEANUP_LOG_DIR:-$(dirname -- "${RUNNER_CLEANUP_LOG_FILE}")}" \
    "${RUNNER_CLEANUP_LOG_FILE}"
fi

trap runner_cleanup_finish EXIT

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/load-config.sh"
load_runner_cleanup_config "${SCRIPT_DIR}"

LOG_DIR=${RUNNER_CLEANUP_LOG_DIR:-/var/log/runner-cleanup}
LOG_FILE=${RUNNER_CLEANUP_LOG_FILE:-${LOG_DIR}/runner-cleanup.log}

if [ "${RUNNER_CLEANUP_LOGGING_INITIALIZED:-0}" != "1" ]; then
  setup_runner_cleanup_logging "${LOG_DIR}" "${LOG_FILE}"
fi

printf '[%s] runner-cleanup start\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf 'config=%s\n' "${RUNNER_CLEANUP_LOADED_CONFIG:-none}"

KEEP_MAX_IMAGES=${KEEP_MAX_IMAGES:-5}
ENABLE_IMAGE_CLEANUP=${ENABLE_IMAGE_CLEANUP:-1}
ENABLE_DOCKER_CACHE_CLEANUP=${ENABLE_DOCKER_CACHE_CLEANUP:-1}
ENABLE_LOCAL_CACHE_CLEANUP=${ENABLE_LOCAL_CACHE_CLEANUP:-1}
DRY_RUN=${DRY_RUN:-1}

IMAGE_MAX_AGE_DAYS=${IMAGE_MAX_AGE_DAYS:-31}

export DRY_RUN

printf 'DRY_RUN=%s\n' "${DRY_RUN}"
printf 'ENABLE_IMAGE_CLEANUP=%s\n' "${ENABLE_IMAGE_CLEANUP}"
printf 'ENABLE_DOCKER_CACHE_CLEANUP=%s\n' "${ENABLE_DOCKER_CACHE_CLEANUP}"
printf 'ENABLE_LOCAL_CACHE_CLEANUP=%s\n' "${ENABLE_LOCAL_CACHE_CLEANUP}"
printf 'IMAGE_MAX_AGE_DAYS=%s\n' "${IMAGE_MAX_AGE_DAYS}"

if [ "${ENABLE_IMAGE_CLEANUP}" = "1" ]; then
  bash "${SCRIPT_DIR}/clear-docker-cache.sh" image-prune
  if [ "${IMAGE_MAX_AGE_DAYS:-0}" -gt 0 ]; then
    bash "${SCRIPT_DIR}/clear-docker-cache.sh" image-age
  fi
fi

if [ "${ENABLE_DOCKER_CACHE_CLEANUP}" = "1" ]; then
  bash "${SCRIPT_DIR}/clear-docker-cache.sh"
fi

if [ "${ENABLE_LOCAL_CACHE_CLEANUP}" = "1" ]; then
  bash "${SCRIPT_DIR}/clear-runner-local-cache.sh"
fi
