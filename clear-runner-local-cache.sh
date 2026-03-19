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
TOP_N_LARGEST=${TOP_N_LARGEST:-20}

ACTIVE_WINDOW_SECONDS=$((ACTIVE_WINDOW_HOURS * 3600))
WORKSPACE_MAX_AGE_SECONDS=$((WORKSPACE_MAX_AGE_DAYS * 86400))
TMP_MAX_AGE_SECONDS=$((TMP_MAX_AGE_DAYS * 86400))
NOW_TS=$(date +%s)

WORK_DIR=$(mktemp -d)
TMP_CANDIDATES_FILE="${WORK_DIR}/tmp_candidates.tsv"
WORKSPACE_CANDIDATES_FILE="${WORK_DIR}/workspace_candidates.tsv"
DUPLICATE_REPORT_FILE="${WORK_DIR}/duplicate_report.tsv"
SUMMARY_FILE="${WORK_DIR}/summary.txt"

declare -A NEWEST_MTIME_CACHE=()
declare -A SIZE_CACHE=()
STATS_CACHE_FILE=""

TMP_COUNT=0
WORKSPACE_COUNT=0
ARCHIVE_COUNT=0
RUNNER_DIR_COUNT=0
TOTAL_DELETE_BYTES=0
DELETED_COUNT=0
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

# Single Python walk returning "mtime size" — caches both values
get_path_stats() {
  local path=$1

  if [ -n "${NEWEST_MTIME_CACHE[${path}]:-}" ]; then
    return 0
  fi

  local result
  result=$(python3 - "$path" <<'PY'
import os, sys
path = sys.argv[1]
try:
    st = os.stat(path, follow_symlinks=False)
except OSError:
    print("0 0"); raise SystemExit(0)
newest = int(st.st_mtime)
size = 0 if os.path.isdir(path) else st.st_size
if os.path.isdir(path):
    for base, dirs, files in os.walk(path):
        for name in dirs + files:
            child = os.path.join(base, name)
            try:
                cst = os.stat(child, follow_symlinks=False)
                newest = max(newest, int(cst.st_mtime))
                if not os.path.isdir(child):
                    size += cst.st_size
            except OSError:
                pass
print(newest, size)
PY
)

  local mtime size
  IFS=' ' read -r mtime size <<< "${result}"
  NEWEST_MTIME_CACHE[${path}]="${mtime}"
  SIZE_CACHE[${path}]="${size}"
}

get_newest_mtime() {
  local path=$1
  get_path_stats "${path}"
  printf '%s\n' "${NEWEST_MTIME_CACHE[${path}]}"
}

get_size() {
  local path=$1
  get_path_stats "${path}"
  printf '%s\n' "${SIZE_CACHE[${path}]}"
}

is_active() {
  local path=$1
  local mtime
  mtime=$(get_newest_mtime "${path}")
  [ $((NOW_TS - mtime)) -lt "${ACTIVE_WINDOW_SECONDS}" ]
}

is_older_than() {
  local path=$1
  local threshold_seconds=$2
  local mtime
  mtime=$(get_newest_mtime "${path}")
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
    mtime=$(get_newest_mtime "${path}")
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

  # Use Python to find leaf project directories under runner-*/hash/namespace[/subgroup]*/project
  # This handles both depth-4 (runner/hash/ns/proj) and deeper paths (runner/hash/ns/sub/proj)
  while IFS=$'\t' read -r path; do
    [ -n "${path}" ] || continue

    if is_active "${path}"; then
      continue
    fi

    if ! is_older_than "${path}" "${WORKSPACE_MAX_AGE_SECONDS}"; then
      continue
    fi

    local size mtime
    size=$(get_size "${path}")
    mtime=$(get_newest_mtime "${path}")
    append_candidate "${WORKSPACE_CANDIDATES_FILE}" "WORKSPACE_REBUILDABLE" "${size}" "${mtime}" "${path}"
  done < <(python3 - "${RUNNER_CACHE_DIR}" <<'PY'
import os, sys

root = sys.argv[1]

for runner_dir in sorted(os.listdir(root)):
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
        # Walk namespace/subgroup tree to find leaf project dirs
        # A "leaf project" is a dir whose children are NOT all directories
        # (i.e., it contains files, or is the deepest meaningful dir)
        def find_projects(base, depth=0):
            try:
                entries = os.listdir(base)
            except PermissionError:
                return
            name = os.path.basename(base)
            if name.startswith('.') or name.endswith('.tmp'):
                return
            # Check if this is a leaf: has any non-directory child, or has no subdirs
            subdirs = []
            has_files = False
            for e in entries:
                if e.startswith('.'):
                    continue
                ep = os.path.join(base, e)
                if os.path.isdir(ep) and not e.endswith('.tmp'):
                    subdirs.append(ep)
                else:
                    has_files = True
            if depth >= 1 and (has_files or not subdirs):
                # This is a leaf project directory
                print(base)
            else:
                for sd in subdirs:
                    find_projects(sd, depth + 1)

        find_projects(level2_path)
PY
)
}

scan_duplicate_workspaces() {
  if [ "${ENABLE_DUPLICATE_WORKSPACE_REPORT}" != "1" ] && [ "${ENABLE_DUPLICATE_WORKSPACE_CLEANUP}" != "1" ]; then
    return 0
  fi

  : > "${DUPLICATE_REPORT_FILE}"

  python3 - "${RUNNER_CACHE_DIR}" "${NOW_TS}" "${ACTIVE_WINDOW_SECONDS}" "${KEEP_WORKSPACE_COPIES}" "${ENABLE_DUPLICATE_WORKSPACE_CLEANUP}" "${WORKSPACE_MAX_AGE_SECONDS}" "${WORKSPACE_CANDIDATES_FILE}" "${DUPLICATE_REPORT_FILE}" "${ENABLE_DUPLICATE_WORKSPACE_REPORT}" "${STATS_CACHE_FILE:-}" <<'PY'
import os
import sys
from collections import defaultdict

root = sys.argv[1]
now_ts = int(sys.argv[2])
active_window = int(sys.argv[3])
keep_copies = int(sys.argv[4])
enable_cleanup = sys.argv[5] == "1"
workspace_max_age = int(sys.argv[6])
workspace_candidates_file = sys.argv[7]
duplicate_report_file = sys.argv[8]
enable_report = sys.argv[9] == "1"
stats_cache_file = sys.argv[10] if len(sys.argv) > 10 else ""

# Load pre-computed stats cache from bash layer
_stats_cache = {}
if stats_cache_file and os.path.isfile(stats_cache_file):
    with open(stats_cache_file, "r") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t", 2)
            if len(parts) == 3:
                _stats_cache[parts[0]] = (int(parts[1]), int(parts[2]))

groups = defaultdict(list)


def recursive_stats(path):
    if path in _stats_cache:
        return _stats_cache[path]

    try:
        root_stat = os.stat(path, follow_symlinks=False)
    except OSError:
        return 0, 0

    newest = int(root_stat.st_mtime)
    size = 0

    if not os.path.isdir(path):
        return newest, root_stat.st_size

    for base, dirs, files in os.walk(path):
        for name in dirs + files:
            child = os.path.join(base, name)
            try:
                st = os.stat(child, follow_symlinks=False)
            except OSError:
                continue
            newest = max(newest, int(st.st_mtime))
            if not os.path.isdir(child):
                size += st.st_size

    _stats_cache[path] = (newest, size)
    return newest, size

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
                newest_mtime, size = recursive_stats(project_path)
                key = f"{namespace}/{project}|{protection}"
                groups[key].append((newest_mtime, size, project_path))

with open(duplicate_report_file, "w", encoding="utf-8") as report, open(workspace_candidates_file, "a", encoding="utf-8") as candidates:
    for key in sorted(groups):
        items = groups[key]
        if len(items) <= 1:
            continue
        items.sort(key=lambda item: item[0], reverse=True)
        namespace_project, protection = key.split("|", 1)
        total_size = sum(item[1] for item in items)
        if enable_report:
            report.write(f"{namespace_project}\t{protection}\t{len(items)}\t{total_size}\n")
        if not enable_cleanup:
            continue
        keep = []
        for item in items:
            mtime, size, path = item
            if now_ts - mtime < active_window:
                keep.append(item)
        protected_keep = max(keep_copies, len(keep))
        for idx, item in enumerate(items):
            if idx < protected_keep:
                continue
            mtime, size, path = item
            if now_ts - mtime < active_window:
                continue
            if now_ts - mtime <= workspace_max_age:
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

EMPTY_RUNNER_DIR_COUNT=0

cleanup_empty_runner_dirs() {
  log "Checking for empty runner directories"
  local dir
  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    # A runner dir is "empty" if it has no files at all (only empty subdirs or nothing)
    if [ -z "$(find "${dir}" -mindepth 1 -type f -print -quit 2>/dev/null)" ]; then
      if [ "${DRY_RUN}" = "1" ]; then
        log "Would remove empty runner dir: ${dir}"
        EMPTY_RUNNER_DIR_COUNT=$((EMPTY_RUNNER_DIR_COUNT + 1))
      else
        if rm -rf -- "${dir}"; then
          EMPTY_RUNNER_DIR_COUNT=$((EMPTY_RUNNER_DIR_COUNT + 1))
          DELETED_COUNT=$((DELETED_COUNT + 1))
          log "Removed empty runner dir: ${dir}"
        else
          FAILED_COUNT=$((FAILED_COUNT + 1))
          log "Failed to remove empty runner dir: ${dir}"
        fi
      fi
    fi
  done < <(find "${RUNNER_CACHE_DIR}" -maxdepth 1 -mindepth 1 -type d -name 'runner-*' 2>/dev/null)
}

print_result() {
  log "Result"
  printf 'dry_run=%s\n' "${DRY_RUN}"
  printf 'planned_or_reclaimed=%s\n' "$(bytes_to_human "${TOTAL_DELETE_BYTES}")"
  printf 'deleted=%s\n' "${DELETED_COUNT}"
  printf 'empty_runner_dirs=%s\n' "${EMPTY_RUNNER_DIR_COUNT}"
  printf 'failed=%s\n' "${FAILED_COUNT}"
}

export_stats_cache() {
  STATS_CACHE_FILE="${WORK_DIR}/stats_cache.tsv"
  : > "${STATS_CACHE_FILE}"
  for path in "${!NEWEST_MTIME_CACHE[@]}"; do
    printf '%s\t%s\t%s\n' "${path}" "${NEWEST_MTIME_CACHE[${path}]}" "${SIZE_CACHE[${path}]:-0}" >> "${STATS_CACHE_FILE}"
  done
}

main() {
  ensure_prerequisites
  print_configuration
  scan_summary
  scan_tmp_candidates
  scan_workspace_candidates
  export_stats_cache
  scan_duplicate_workspaces
  print_summary
  emit_candidates "${TMP_CANDIDATES_FILE}" "SAFE_TMP candidates"
  emit_candidates "${WORKSPACE_CANDIDATES_FILE}" "WORKSPACE_REBUILDABLE candidates"
  execute_candidates "${TMP_CANDIDATES_FILE}" "Executing SAFE_TMP cleanup"
  execute_candidates "${WORKSPACE_CANDIDATES_FILE}" "Executing WORKSPACE_REBUILDABLE cleanup"
  cleanup_empty_runner_dirs
  print_result
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
