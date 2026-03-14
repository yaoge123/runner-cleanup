#!/usr/bin/env bash

load_runner_cleanup_config() {
  local script_dir=${1:-}
  local config_path=${RUNNER_CLEANUP_CONFIG:-}

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

    # shellcheck disable=SC1090
    . "${config_path}"
  fi
}
