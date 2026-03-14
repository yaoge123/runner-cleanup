#!/usr/bin/env bash

IFS=$'\n\t'
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/load-config.sh"
load_runner_cleanup_config "${SCRIPT_DIR}"

RUNNER_CACHE_DIR=${RUNNER_CACHE_DIR:-/cache}
DRY_RUN=${DRY_RUN:-1}
VERBOSE=${VERBOSE:-1}

ENABLE_TMP_CLEANUP=${ENABLE_TMP_CLEANUP:-1}
ENABLE_WORKSPACE_CLEANUP=${ENABLE_WORKSPACE_CLEANUP:-1}
ENABLE_DUPLICATE_WORKSPACE_REPORT=${ENABLE_DUPLICATE_WORKSPACE_REPORT:-1}
ENABLE_DUPLICATE_WORKSPACE_CLEANUP=${ENABLE_DUPLICATE_WORKSPACE_CLEANUP:-1}
ENABLE_ARCHIVE_CLEANUP=${ENABLE_ARCHIVE_CLEANUP:-0}

TMP_MAX_AGE_DAYS=${TMP_MAX_AGE_DAYS:-1}
WORKSPACE_MAX_AGE_DAYS=${WORKSPACE_MAX_AGE_DAYS:-7}
ACTIVE_WINDOW_HOURS=${ACTIVE_WINDOW_HOURS:-48}
KEEP_WORKSPACE_COPIES=${KEEP_WORKSPACE_COPIES:-1}
MAX_DELETE_GB_PER_RUN=${MAX_DELETE_GB_PER_RUN:-10}
TOP_N_LARGEST=${TOP_N_LARGEST:-20}

ACTIVE_WINDOW_SECONDS=$((ACTIVE_WINDOW_HOURS * 3600))
WORKSPACE_MAX_AGE_SECONDS=$((WORKSPACE_MAX_AGE_DAYS * 86400))
TMP_MAX_AGE_SECONDS=$((TMP_MAX_AGE_DAYS * 86400))
MAX_DELETE_BYTES=$((MAX_DELETE_GB_PER_RUN * 1024 * 1024 * 1024))
NOW_TS=$(date +%s)

WORK_DIR=$(mktemp -d)
TMP_CANDIDATES_FILE="${WORK_DIR}/tmp_candidates.tsv"
WORKSPACE_CANDIDATES_FILE="${WORK_DIR}/workspace_candidates.tsv"
DUPLICATE_REPORT_FILE="${WORK_DIR}/duplicate_report.tsv"
SUMMARY_FILE="${WORK_DIR}/summary.txt"

TMP_COUNT=0
WORKSPACE_COUNT=0
ARCHIVE_COUNT=0
RUNNER_DIR_COUNT=0
TOTAL_DELETE_BYTES=0
DELETED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

verbose() {
  if [ "${VERBOSE}" = "1" ]; then
    log "$@"
  fi
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

bytes_to_human() {
  local bytes=$1
  local units=(B KB MB GB TB)
  local idx=0
  local value=$bytes

  while [ "$value" -ge 1024 ] && [ "$idx" -lt 4 ]; do
    value=$((value / 1024))
    idx=$((idx + 1))
  done

  printf '%s %s' "$value" "${units[$idx]}"
}

path_allowed() {
  case "$1" in
    /cache|/home/gitlab-runner/cache|/var/lib/gitlab-runner/cache)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_prerequisites() {
  path_allowed "${RUNNER_CACHE_DIR}" || fail "RUNNER_CACHE_DIR ${RUNNER_CACHE_DIR} is not in the allowlist"
  [ -d "${RUNNER_CACHE_DIR}" ] || fail "RUNNER_CACHE_DIR ${RUNNER_CACHE_DIR} does not exist"
  [ "${RUNNER_CACHE_DIR}" != "/" ] || fail "Refusing to operate on root directory"
}

get_mtime() {
  stat -c %Y "$1"
}

get_size() {
  du -sb "$1" 2>/dev/null | cut -f1
}

is_active() {
  local path=$1
  local mtime
  mtime=$(get_mtime "${path}")
  [ $((NOW_TS - mtime)) -lt "${ACTIVE_WINDOW_SECONDS}" ]
}

is_older_than() {
  local path=$1
  local threshold_seconds=$2
  local mtime
  mtime=$(get_mtime "${path}")
  [ $((NOW_TS - mtime)) -gt "${threshold_seconds}" ]
}

append_candidate() {
  local file=$1
  local label=$2
  local size=$3
  local mtime=$4
  local path=$5

  printf '%s\t%s\t%s\t%s\n' "${label}" "${size}" "${mtime}" "${path}" >> "${file}"
}

scan_summary() {
  RUNNER_DIR_COUNT=$( (find "${RUNNER_CACHE_DIR}" -maxdepth 1 -mindepth 1 -type d -name 'runner-*' 2>/dev/null || true) | wc -l | tr -d ' ' )
  TMP_COUNT=$( (find "${RUNNER_CACHE_DIR}" -type d -name '*.tmp' 2>/dev/null || true) | wc -l | tr -d ' ' )
  ARCHIVE_COUNT=$( (find "${RUNNER_CACHE_DIR}" -type f -name 'cache.zip' 2>/dev/null || true) | wc -l | tr -d ' ' )

  {
    printf 'runner_dirs=%s\n' "${RUNNER_DIR_COUNT}"
    printf 'tmp_dirs=%s\n' "${TMP_COUNT}"
    printf 'archive_files=%s\n' "${ARCHIVE_COUNT}"
  } > "${SUMMARY_FILE}"
}

scan_tmp_candidates() {
  [ "${ENABLE_TMP_CLEANUP}" = "1" ] || return 0

  : > "${TMP_CANDIDATES_FILE}"

  while IFS= read -r path; do
    [ -n "${path}" ] || continue

    if is_active "${path}"; then
      continue
    fi

    local size mtime label
    size=$(get_size "${path}")
    mtime=$(get_mtime "${path}")
    label="SAFE_TMP"

    if [ -z "$(find "${path}" -mindepth 1 -print -quit 2>/dev/null)" ]; then
      append_candidate "${TMP_CANDIDATES_FILE}" "${label}" "${size}" "${mtime}" "${path}"
      continue
    fi

    if is_older_than "${path}" "${TMP_MAX_AGE_SECONDS}"; then
      append_candidate "${TMP_CANDIDATES_FILE}" "${label}" "${size}" "${mtime}" "${path}"
    fi
  done < <(find "${RUNNER_CACHE_DIR}" -type d -name '*.tmp' 2>/dev/null)
}

scan_workspace_candidates() {
  [ "${ENABLE_WORKSPACE_CLEANUP}" = "1" ] || return 0

  : > "${WORKSPACE_CANDIDATES_FILE}"

  while IFS= read -r path; do
    [ -n "${path}" ] || continue

    case "$(basename "${path}")" in
      *.tmp)
        continue
        ;;
    esac

    case "${path}" in
      */.*|*/.*/**)
        continue
        ;;
    esac

    if is_active "${path}"; then
      continue
    fi

    if ! is_older_than "${path}" "${WORKSPACE_MAX_AGE_SECONDS}"; then
      continue
    fi

    local size mtime
    size=$(get_size "${path}")
    mtime=$(get_mtime "${path}")
    append_candidate "${WORKSPACE_CANDIDATES_FILE}" "WORKSPACE_REBUILDABLE" "${size}" "${mtime}" "${path}"
  done < <(find "${RUNNER_CACHE_DIR}" -mindepth 4 -maxdepth 4 -type d -path "${RUNNER_CACHE_DIR}/runner-*/*/*/*" 2>/dev/null)
}

scan_duplicate_workspaces() {
  [ "${ENABLE_DUPLICATE_WORKSPACE_REPORT}" = "1" ] || return 0

  : > "${DUPLICATE_REPORT_FILE}"

  python3 - "${RUNNER_CACHE_DIR}" "${NOW_TS}" "${ACTIVE_WINDOW_SECONDS}" "${KEEP_WORKSPACE_COPIES}" "${ENABLE_DUPLICATE_WORKSPACE_CLEANUP}" "${WORKSPACE_CANDIDATES_FILE}" "${DUPLICATE_REPORT_FILE}" <<'PY'
import os
import sys
from collections import defaultdict

root = sys.argv[1]
now_ts = int(sys.argv[2])
active_window = int(sys.argv[3])
keep_copies = int(sys.argv[4])
enable_cleanup = sys.argv[5] == "1"
workspace_candidates_file = sys.argv[6]
duplicate_report_file = sys.argv[7]

groups = defaultdict(list)

for runner_dir in os.listdir(root):
    if not runner_dir.startswith("runner-"):
        continue
    runner_path = os.path.join(root, runner_dir)
    if not os.path.isdir(runner_path):
        continue
    try:
        level2_entries = os.listdir(runner_path)
    except PermissionError:
        continue
    for level2 in level2_entries:
        level2_path = os.path.join(runner_path, level2)
        if not os.path.isdir(level2_path):
            continue
        protection = "protected" if level2.endswith("-protected") else "unprotected"
        try:
            namespaces = os.listdir(level2_path)
        except PermissionError:
            continue
        for namespace in namespaces:
            if namespace.startswith('.'):
                continue
            namespace_path = os.path.join(level2_path, namespace)
            if not os.path.isdir(namespace_path):
                continue
            try:
                projects = os.listdir(namespace_path)
            except PermissionError:
                continue
            for project in projects:
                if project.startswith('.') or project.endswith('.tmp'):
                    continue
                project_path = os.path.join(namespace_path, project)
                if not os.path.isdir(project_path):
                    continue
                try:
                    st = os.stat(project_path)
                except FileNotFoundError:
                    continue
                size = 0
                for base, dirs, files in os.walk(project_path):
                    for name in files:
                        fp = os.path.join(base, name)
                        try:
                            size += os.path.getsize(fp)
                        except OSError:
                            pass
                key = f"{namespace}/{project}|{protection}"
                groups[key].append((int(st.st_mtime), size, project_path))

with open(duplicate_report_file, "w", encoding="utf-8") as report, open(workspace_candidates_file, "a", encoding="utf-8") as candidates:
    for key in sorted(groups):
        items = groups[key]
        if len(items) <= 1:
            continue
        items.sort(key=lambda item: item[0], reverse=True)
        namespace_project, protection = key.split("|", 1)
        total_size = sum(item[1] for item in items)
        report.write(f"{namespace_project}\t{protection}\t{len(items)}\t{total_size}\n")
        if not enable_cleanup:
            continue
        keep = []
        removable = []
        for item in items:
            mtime, size, path = item
            if now_ts - mtime < active_window:
                keep.append(item)
            else:
                removable.append(item)
        protected_keep = max(keep_copies, len(keep))
        for idx, item in enumerate(items):
            if idx < protected_keep:
                continue
            mtime, size, path = item
            if now_ts - mtime < active_window:
                continue
            candidates.write(f"WORKSPACE_REBUILDABLE\t{size}\t{mtime}\t{path}\n")
PY
}

print_configuration() {
  log "Configuration"
  printf 'RUNNER_CACHE_DIR=%s\n' "${RUNNER_CACHE_DIR}"
  printf 'DRY_RUN=%s\n' "${DRY_RUN}"
  printf 'ENABLE_TMP_CLEANUP=%s\n' "${ENABLE_TMP_CLEANUP}"
  printf 'ENABLE_WORKSPACE_CLEANUP=%s\n' "${ENABLE_WORKSPACE_CLEANUP}"
  printf 'ENABLE_DUPLICATE_WORKSPACE_REPORT=%s\n' "${ENABLE_DUPLICATE_WORKSPACE_REPORT}"
  printf 'ENABLE_DUPLICATE_WORKSPACE_CLEANUP=%s\n' "${ENABLE_DUPLICATE_WORKSPACE_CLEANUP}"
  printf 'ENABLE_ARCHIVE_CLEANUP=%s\n' "${ENABLE_ARCHIVE_CLEANUP}"
  printf 'TMP_MAX_AGE_DAYS=%s\n' "${TMP_MAX_AGE_DAYS}"
  printf 'WORKSPACE_MAX_AGE_DAYS=%s\n' "${WORKSPACE_MAX_AGE_DAYS}"
  printf 'ACTIVE_WINDOW_HOURS=%s\n' "${ACTIVE_WINDOW_HOURS}"
  printf 'KEEP_WORKSPACE_COPIES=%s\n' "${KEEP_WORKSPACE_COPIES}"
  printf 'MAX_DELETE_GB_PER_RUN=%s\n' "${MAX_DELETE_GB_PER_RUN}"
}

print_summary() {
  log "Scan Summary"
  cat "${SUMMARY_FILE}"

  log "Largest runner directories"
  du -sh "${RUNNER_CACHE_DIR}"/runner-* 2>/dev/null | sort -h | tail -n "${TOP_N_LARGEST}" || true

  if [ -s "${DUPLICATE_REPORT_FILE}" ]; then
    log "Duplicate workspace groups"
    while IFS=$'\t' read -r name protection count size; do
      printf '%s\t%s\t%s copies\t%s\n' "${name}" "${protection}" "${count}" "$(bytes_to_human "${size}")"
    done < "${DUPLICATE_REPORT_FILE}"
  fi
}

emit_candidates() {
  local file=$1
  local title=$2

  if [ ! -s "${file}" ]; then
    return 0
  fi

  log "${title}"
  awk -F '\t' '!seen[$4]++' "${file}" | sort -t $'\t' -k3,3n -k4,4 | while IFS=$'\t' read -r label size mtime path; do
    printf '%s\t%s\t%s\t%s\n' "${label}" "$(bytes_to_human "${size}")" "$(date -d "@${mtime}" '+%Y-%m-%d %H:%M:%S')" "${path}"
  done
}

execute_candidates() {
  local file=$1
  local title=$2

  [ -s "${file}" ] || return 0
  log "${title}"

  while IFS=$'\t' read -r label size mtime path; do
    if [ $((TOTAL_DELETE_BYTES + size)) -gt "${MAX_DELETE_BYTES}" ]; then
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      log "Skipped due to MAX_DELETE_GB_PER_RUN: ${path}"
      continue
    fi

    if [ "${DRY_RUN}" = "1" ]; then
      TOTAL_DELETE_BYTES=$((TOTAL_DELETE_BYTES + size))
      log "Would remove ${label}: ${path} ($(bytes_to_human "${size}"))"
      continue
    fi

    if rm -rf -- "${path}"; then
      TOTAL_DELETE_BYTES=$((TOTAL_DELETE_BYTES + size))
      DELETED_COUNT=$((DELETED_COUNT + 1))
      log "Removed ${label}: ${path} ($(bytes_to_human "${size}"))"
    else
      FAILED_COUNT=$((FAILED_COUNT + 1))
      log "Failed to remove ${label}: ${path}"
    fi
  done < <(awk -F '\t' '!seen[$4]++' "${file}" | sort -t $'\t' -k3,3n -k2,2nr -k4,4)
}

print_result() {
  log "Result"
  printf 'dry_run=%s\n' "${DRY_RUN}"
  printf 'planned_or_reclaimed=%s\n' "$(bytes_to_human "${TOTAL_DELETE_BYTES}")"
  printf 'deleted=%s\n' "${DELETED_COUNT}"
  printf 'skipped=%s\n' "${SKIPPED_COUNT}"
  printf 'failed=%s\n' "${FAILED_COUNT}"
}

main() {
  ensure_prerequisites
  print_configuration
  scan_summary
  scan_tmp_candidates
  scan_workspace_candidates
  scan_duplicate_workspaces
  print_summary
  emit_candidates "${TMP_CANDIDATES_FILE}" "SAFE_TMP candidates"
  emit_candidates "${WORKSPACE_CANDIDATES_FILE}" "WORKSPACE_REBUILDABLE candidates"
  execute_candidates "${TMP_CANDIDATES_FILE}" "Executing SAFE_TMP cleanup"
  execute_candidates "${WORKSPACE_CANDIDATES_FILE}" "Executing WORKSPACE_REBUILDABLE cleanup"
  print_result
}

main "$@"
