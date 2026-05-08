#!/usr/bin/env bash

resolve_runner_cleanup_path() {
  local path=$1
  local dir base

  dir=$(cd -- "$(dirname -- "${path}")" && pwd)
  base=$(basename -- "${path}")
  printf '%s/%s\n' "${dir}" "${base}"
}

declare -A RUNNER_CLEANUP_ENV_PRESENT=()
declare -A RUNNER_CLEANUP_ENV_VALUES=()

snapshot_runner_cleanup_env() {
  local var

  RUNNER_CLEANUP_ENV_PRESENT=()
  RUNNER_CLEANUP_ENV_VALUES=()

  for var in \
    KEEP_MAX_IMAGES \
    ENABLE_IMAGE_CLEANUP \
    ENABLE_DOCKER_CACHE_CLEANUP \
    ENABLE_LOCAL_CACHE_CLEANUP \
    RUNNER_CACHE_DIR \
    DRY_RUN \
    VERBOSE \
    ENABLE_TMP_CLEANUP \
    ENABLE_WORKSPACE_CLEANUP \
    ENABLE_ARCHIVE_CLEANUP \
    TMP_MAX_AGE_DAYS \
    WORKSPACE_MAX_AGE_DAYS \
    ARCHIVE_MAX_AGE_DAYS \
    TOP_N_LARGEST \
    RUNNER_CLEANUP_LOG_DIR \
    RUNNER_CLEANUP_LOG_FILE \
    RUNNER_CLEANUP_LOGGING_INITIALIZED; do
    if [ "${!var+x}" = "x" ]; then
      RUNNER_CLEANUP_ENV_PRESENT[${var}]=1
      RUNNER_CLEANUP_ENV_VALUES[${var}]="${!var}"
    fi
  done
}

restore_runner_cleanup_env() {
  local var

  for var in "${!RUNNER_CLEANUP_ENV_PRESENT[@]}"; do
    printf -v "${var}" '%s' "${RUNNER_CLEANUP_ENV_VALUES[${var}]}"
    export "${var}"
  done
}

load_runner_cleanup_config() {
  local script_dir=${1:-}
  local config_path=${RUNNER_CLEANUP_CONFIG:-}

  RUNNER_CLEANUP_ENV_PRESENT=()
  RUNNER_CLEANUP_ENV_VALUES=()

  if [ -z "${config_path}" ] && [ -n "${script_dir}" ] && [ -f "${script_dir}/runner-cleanup.conf" ]; then
    config_path="${script_dir}/runner-cleanup.conf"
  fi

  if [ -z "${config_path}" ] && [ -f "./runner-cleanup.conf" ]; then
    config_path="./runner-cleanup.conf"
  fi

  if [ -n "${config_path}" ]; then
    if [ ! -f "${config_path}" ]; then
      printf 'ERROR: config file not found: %s\n' "${config_path}" >&2
      return 1
    fi

    config_path=$(resolve_runner_cleanup_path "${config_path}")
    snapshot_runner_cleanup_env

    # shellcheck disable=SC1090
    . "${config_path}"
    restore_runner_cleanup_env
    export RUNNER_CLEANUP_LOADED_CONFIG="${config_path}"
  else
    unset RUNNER_CLEANUP_LOADED_CONFIG 2>/dev/null || true
  fi
}
