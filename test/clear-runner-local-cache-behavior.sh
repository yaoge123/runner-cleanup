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

build_workspace_tree() {
  local root=$1

  mkdir -p "${root}/runner-a/hash-protected/ns/project-a"
  mkdir -p "${root}/runner-b/hash-protected/ns/project-a"
  mkdir -p "${root}/runner-d/hash-protected/ns/project-a"
  mkdir -p "${root}/runner-c/hash-protected/ns/project-b"

  printf 'old-a' > "${root}/runner-a/hash-protected/ns/project-a/file.txt"
  printf 'new-a' > "${root}/runner-b/hash-protected/ns/project-a/file.txt"
  printf 'mid-a' > "${root}/runner-d/hash-protected/ns/project-a/file.txt"
  printf 'new-b' > "${root}/runner-c/hash-protected/ns/project-b/file.txt"
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

CONFIG_FILE="${TMP_DIR}/runner-cleanup.conf"
cat > "${CONFIG_FILE}" <<EOF
RUNNER_CACHE_DIR=${CACHE_ROOT}
ENABLE_TMP_CLEANUP=0
ENABLE_WORKSPACE_CLEANUP=1
ENABLE_DUPLICATE_WORKSPACE_REPORT=1
ENABLE_DUPLICATE_WORKSPACE_CLEANUP=1
WORKSPACE_MAX_AGE_DAYS=7
ACTIVE_WINDOW_HOURS=48
KEEP_WORKSPACE_COPIES=1
EOF

RUNNER_CLEANUP_CONFIG="${CONFIG_FILE}" . "${REPO_DIR}/clear-runner-local-cache.sh"

actual_config=${RUNNER_CLEANUP_LOADED_CONFIG:-}
assert_eq "${CONFIG_FILE}" "${actual_config}" "loaded config path should be exported"

newest_old=$(get_newest_mtime "${CACHE_ROOT}/runner-a/hash-protected/ns/project-a")
newest_recent=$(get_newest_mtime "${CACHE_ROOT}/runner-b/hash-protected/ns/project-a")

assert_eq "${OLD_TS}" "${newest_old}" "old workspace should report old recursive mtime"
assert_eq "${RECENT_TS}" "${newest_recent}" "recent child activity should update recursive mtime"

if is_active "${CACHE_ROOT}/runner-a/hash-protected/ns/project-a"; then
  printf 'old workspace unexpectedly treated as active\n' >&2
  exit 1
fi

if ! is_active "${CACHE_ROOT}/runner-b/hash-protected/ns/project-a"; then
  printf 'recent child activity should keep workspace active\n' >&2
  exit 1
fi

scan_summary
scan_workspace_candidates
scan_duplicate_workspaces

assert_file_contains "${WORKSPACE_CANDIDATES_FILE}" "runner-a/hash-protected/ns/project-a"

if grep -q 'runner-b/hash-protected/ns/project-a' "${WORKSPACE_CANDIDATES_FILE}"; then
  printf 'duplicate cleanup should not delete a recent duplicate copy\n' >&2
  exit 1
fi

if grep -q 'runner-d/hash-protected/ns/project-a' "${WORKSPACE_CANDIDATES_FILE}"; then
  printf 'duplicate cleanup should keep a non-active duplicate that is newer than WORKSPACE_MAX_AGE_DAYS\n' >&2
  exit 1
fi

if grep -q 'runner-c/hash-protected/ns/project-b' "${WORKSPACE_CANDIDATES_FILE}"; then
  printf 'active non-duplicate workspace should not become a cleanup candidate\n' >&2
  exit 1
fi

: > "${WORKSPACE_CANDIDATES_FILE}"
ENABLE_DUPLICATE_WORKSPACE_REPORT=0
ENABLE_DUPLICATE_WORKSPACE_CLEANUP=1
scan_duplicate_workspaces

assert_file_contains "${WORKSPACE_CANDIDATES_FILE}" "runner-a/hash-protected/ns/project-a"
