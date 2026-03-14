#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

CONFIG_FILE="${TMP_DIR}/runner-cleanup.conf"
LOG_DIR="${TMP_DIR}/logs"
LOG_FILE="${LOG_DIR}/runner-cleanup.log"

cat >"${CONFIG_FILE}" <<EOF
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

if [ ! -f "${LOG_FILE}" ]; then
  printf 'expected log file to exist: %s\n' "${LOG_FILE}" >&2
  exit 1
fi

grep -q 'runner-cleanup start' "${LOG_FILE}"
grep -q 'config=' "${LOG_FILE}"
grep -q 'runner-cleanup end exit_code=0' "${LOG_FILE}"
