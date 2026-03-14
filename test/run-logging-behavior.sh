#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

assert_file_contains() {
  local path=$1
  local pattern=$2

  if ! grep -q -- "${pattern}" "${path}"; then
    printf 'expected file to contain pattern\nfile: %s\npattern: %s\n' "${path}" "${pattern}" >&2
    exit 1
  fi
}

CONFIG_FILE="${TMP_DIR}/runner-cleanup.conf"
LOG_DIR="${TMP_DIR}/logs"
LOG_FILE="${LOG_DIR}/runner-cleanup.log"

cat > "${CONFIG_FILE}" <<EOF
ENABLE_IMAGE_CLEANUP=0
ENABLE_DOCKER_CACHE_CLEANUP=0
ENABLE_LOCAL_CACHE_CLEANUP=0
RUNNER_CLEANUP_LOG_DIR=${LOG_DIR}
RUNNER_CLEANUP_LOG_FILE=${LOG_FILE}
EOF

RUNNER_CLEANUP_CONFIG="${CONFIG_FILE}" \
RUNNER_CLEANUP_LOG_DIR="${LOG_DIR}" \
RUNNER_CLEANUP_LOG_FILE="${LOG_FILE}" \
  bash "${REPO_DIR}/run.sh"

assert_file_contains "${LOG_FILE}" "runner-cleanup start"
assert_file_contains "${LOG_FILE}" "config=${CONFIG_FILE}"
assert_file_contains "${LOG_FILE}" "runner-cleanup end exit_code=0"

OVERRIDE_LOG_DIR="${TMP_DIR}/override-logs"
OVERRIDE_LOG_FILE="${OVERRIDE_LOG_DIR}/runner-cleanup.log"
OVERRIDE_CONFIG_FILE="${TMP_DIR}/override.conf"

cat > "${OVERRIDE_CONFIG_FILE}" <<EOF
ENABLE_IMAGE_CLEANUP=0
ENABLE_DOCKER_CACHE_CLEANUP=0
ENABLE_LOCAL_CACHE_CLEANUP=0
RUNNER_CLEANUP_LOG_DIR=${TMP_DIR}/ignored-by-config
RUNNER_CLEANUP_LOG_FILE=${TMP_DIR}/ignored-by-config/runner-cleanup.log
EOF

RUNNER_CLEANUP_CONFIG="${OVERRIDE_CONFIG_FILE}" \
RUNNER_CLEANUP_LOG_DIR="${OVERRIDE_LOG_DIR}" \
RUNNER_CLEANUP_LOG_FILE="${OVERRIDE_LOG_FILE}" \
  bash "${REPO_DIR}/run.sh"

if [ ! -f "${OVERRIDE_LOG_FILE}" ]; then
  printf 'expected env override log file to exist: %s\n' "${OVERRIDE_LOG_FILE}" >&2
  exit 1
fi

if [ -e "${TMP_DIR}/ignored-by-config/runner-cleanup.log" ]; then
  printf 'config file should not override explicit log path environment variables\n' >&2
  exit 1
fi

assert_file_contains "${OVERRIDE_LOG_FILE}" "config=${OVERRIDE_CONFIG_FILE}"

AUTO_DIR="${TMP_DIR}/auto"
AUTO_LOG_DIR="${AUTO_DIR}/logs"
AUTO_LOG_FILE="${AUTO_LOG_DIR}/runner-cleanup.log"
mkdir -p "${AUTO_DIR}"

cat > "${AUTO_DIR}/runner-cleanup.conf" <<EOF
ENABLE_IMAGE_CLEANUP=0
ENABLE_DOCKER_CACHE_CLEANUP=0
ENABLE_LOCAL_CACHE_CLEANUP=1
RUNNER_CACHE_DIR=${TMP_DIR}/does-not-exist
RUNNER_CLEANUP_LOG_DIR=${AUTO_LOG_DIR}
RUNNER_CLEANUP_LOG_FILE=${AUTO_LOG_FILE}
EOF

set +e
( cd "${AUTO_DIR}" && RUNNER_CLEANUP_LOG_DIR="${AUTO_LOG_DIR}" RUNNER_CLEANUP_LOG_FILE="${AUTO_LOG_FILE}" bash "${REPO_DIR}/run.sh" )
exit_code=$?
set -e

if [ "${exit_code}" -eq 0 ]; then
  printf 'expected run.sh to fail when local cleanup points to a missing cache dir\n' >&2
  exit 1
fi

assert_file_contains "${AUTO_LOG_FILE}" "config=${AUTO_DIR}/runner-cleanup.conf"
assert_file_contains "${AUTO_LOG_FILE}" "ERROR:"
assert_file_contains "${AUTO_LOG_FILE}" "runner-cleanup end exit_code=${exit_code}"

MISSING_LOG_DIR="${TMP_DIR}/missing-config-logs"
MISSING_LOG_FILE="${MISSING_LOG_DIR}/runner-cleanup.log"

set +e
RUNNER_CLEANUP_CONFIG="${TMP_DIR}/missing.conf" \
RUNNER_CLEANUP_LOG_DIR="${MISSING_LOG_DIR}" \
RUNNER_CLEANUP_LOG_FILE="${MISSING_LOG_FILE}" \
  bash "${REPO_DIR}/run.sh"
missing_exit_code=$?
set -e

if [ "${missing_exit_code}" -eq 0 ]; then
  printf 'expected run.sh to fail when RUNNER_CLEANUP_CONFIG points to a missing file\n' >&2
  exit 1
fi

assert_file_contains "${MISSING_LOG_FILE}" "ERROR: config file not found"
assert_file_contains "${MISSING_LOG_FILE}" "runner-cleanup end exit_code=${missing_exit_code}"
