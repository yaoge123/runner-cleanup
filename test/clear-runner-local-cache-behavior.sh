#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

assert_eq() {
  local expected=$1
  local actual=$2
  local message=$3

  if [ "${expected}" != "${actual}" ]; then
    printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "${message}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

assert_file_contains() {
  local path=$1
  local pattern=$2

  if ! grep -q -- "${pattern}" "${path}"; then
    printf 'expected file to contain pattern\nfile: %s\npattern: %s\n' "${path}" "${pattern}" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local path=$1
  local pattern=$2

  if grep -q -- "${pattern}" "${path}"; then
    printf 'expected file to not contain pattern\nfile: %s\npattern: %s\n' "${path}" "${pattern}" >&2
    exit 1
  fi
}

build_workspace_tree() {
  local root=$1

  mkdir -p "${root}/runner-a/hash-protected/ns/project-a"
  mkdir -p "${root}/runner-b/hash-protected/ns/project-a"
  mkdir -p "${root}/runner-d/hash-protected/ns/project-a"
  mkdir -p "${root}/runner-c/hash-protected/ns/project-b"
  mkdir -p "${root}/runner-e/hash-protected/ns/project-c/.git"
  mkdir -p "${root}/runner-f/hash-protected/.pnpm-store"

  printf 'old-a' > "${root}/runner-a/hash-protected/ns/project-a/file.txt"
  printf 'new-a' > "${root}/runner-b/hash-protected/ns/project-a/file.txt"
  printf 'mid-a' > "${root}/runner-d/hash-protected/ns/project-a/file.txt"
  printf 'new-b' > "${root}/runner-c/hash-protected/ns/project-b/file.txt"
  printf 'new-git' > "${root}/runner-e/hash-protected/ns/project-c/.git/HEAD"
  printf 'old-store' > "${root}/runner-f/hash-protected/.pnpm-store/store.txt"
}

set_mtime() {
  local path=$1
  local timestamp=$2
  touch -d "@${timestamp}" "${path}"
}

NOW_TS=$(date +%s)
OLD_TS=$((NOW_TS - 10 * 86400))
MID_TS=$((NOW_TS - 3 * 86400))
RECENT_TS=$((NOW_TS - 2 * 3600))

CACHE_ROOT="${TMP_DIR}/cache"
mkdir -p "${CACHE_ROOT}"
build_workspace_tree "${CACHE_ROOT}"

set_mtime "${CACHE_ROOT}/runner-a/hash-protected/ns/project-a" "${OLD_TS}"
set_mtime "${CACHE_ROOT}/runner-a/hash-protected/ns/project-a/file.txt" "${OLD_TS}"

set_mtime "${CACHE_ROOT}/runner-b/hash-protected/ns/project-a" "${OLD_TS}"
set_mtime "${CACHE_ROOT}/runner-b/hash-protected/ns/project-a/file.txt" "${RECENT_TS}"

set_mtime "${CACHE_ROOT}/runner-d/hash-protected/ns/project-a" "${OLD_TS}"
set_mtime "${CACHE_ROOT}/runner-d/hash-protected/ns/project-a/file.txt" "${MID_TS}"

set_mtime "${CACHE_ROOT}/runner-c/hash-protected/ns/project-b" "${OLD_TS}"
set_mtime "${CACHE_ROOT}/runner-c/hash-protected/ns/project-b/file.txt" "${RECENT_TS}"

set_mtime "${CACHE_ROOT}/runner-e/hash-protected/ns/project-c" "${OLD_TS}"
set_mtime "${CACHE_ROOT}/runner-e/hash-protected/ns/project-c/.git" "${OLD_TS}"
set_mtime "${CACHE_ROOT}/runner-e/hash-protected/ns/project-c/.git/HEAD" "${RECENT_TS}"

set_mtime "${CACHE_ROOT}/runner-f/hash-protected/.pnpm-store" "${OLD_TS}"
set_mtime "${CACHE_ROOT}/runner-f/hash-protected/.pnpm-store/store.txt" "${OLD_TS}"

CONFIG_FILE="${TMP_DIR}/runner-cleanup.conf"
cat > "${CONFIG_FILE}" <<EOF
RUNNER_CACHE_DIR=${CACHE_ROOT}
RUNNER_CACHE_DIR_ALLOWLIST=${CACHE_ROOT}
ENABLE_TMP_CLEANUP=0
ENABLE_WORKSPACE_CLEANUP=1
WORKSPACE_MAX_AGE_DAYS=7
EOF

OUTPUT_LOG="${TMP_DIR}/output.log"
RUNNER_CLEANUP_CONFIG="${CONFIG_FILE}" bash "${REPO_DIR}/clear-runner-local-cache.sh" > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" "config=${CONFIG_FILE}"
assert_file_contains "${OUTPUT_LOG}" "runner-a/hash-protected/ns/project-a"
assert_file_contains "${OUTPUT_LOG}" "runner-f/hash-protected/.pnpm-store"

assert_file_not_contains "${OUTPUT_LOG}" 'runner-b/hash-protected/ns/project-a'
assert_file_not_contains "${OUTPUT_LOG}" 'runner-d/hash-protected/ns/project-a'
assert_file_not_contains "${OUTPUT_LOG}" 'runner-c/hash-protected/ns/project-b'
assert_file_not_contains "${OUTPUT_LOG}" 'runner-e/hash-protected/ns/project-c/.git'
