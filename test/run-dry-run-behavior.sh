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

assert_file_not_contains() {
  local path=$1
  local pattern=$2

  if grep -q -- "${pattern}" "${path}"; then
    printf 'expected file to not contain pattern\nfile: %s\npattern: %s\n' "${path}" "${pattern}" >&2
    exit 1
  fi
}

assert_file_equals() {
  local path=$1
  local expected=$2

  if [ "$(cat "${path}")" != "${expected}" ]; then
    printf 'expected file to equal\nfile: %s\n--- actual ---\n%s\n--- expected ---\n%s\n' \
      "${path}" "$(cat "${path}")" "${expected}" >&2
    exit 1
  fi
}

make_fake_repo() {
  local root=$1

  cp "${REPO_DIR}/run.sh" "${root}/run.sh"
  cp "${REPO_DIR}/load-config.sh" "${root}/load-config.sh"

  cat > "${root}/clean.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'clean:%s:%s\n' "${DRY_RUN:-unset}" "$1" >> "${RUNNER_CLEANUP_TEST_CALLS}"
EOF

  cat > "${root}/clear-docker-cache.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker:%s\n' "${DRY_RUN:-unset}" >> "${RUNNER_CLEANUP_TEST_CALLS}"
EOF

  cat > "${root}/clear-runner-local-cache.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'local:%s\n' "${DRY_RUN:-unset}" >> "${RUNNER_CLEANUP_TEST_CALLS}"
EOF

  chmod +x "${root}/run.sh" "${root}/clean.sh" "${root}/clear-docker-cache.sh" "${root}/clear-runner-local-cache.sh"
}

run_case() {
  local case_dir=$1
  local dry_run_value=$2
  local calls_file=$3
  local log_dir="${case_dir}/logs"
  local log_file="${log_dir}/runner-cleanup.log"
  local config_file="${case_dir}/runner-cleanup.conf"

  mkdir -p "${case_dir}"
  make_fake_repo "${case_dir}"

  cat > "${config_file}" <<EOF
KEEP_MAX_IMAGES=7
ENABLE_IMAGE_CLEANUP=1
ENABLE_DOCKER_CACHE_CLEANUP=1
ENABLE_LOCAL_CACHE_CLEANUP=1
RUNNER_CLEANUP_LOG_DIR=${log_dir}
RUNNER_CLEANUP_LOG_FILE=${log_file}
EOF

  if [ -n "${dry_run_value}" ]; then
    RUNNER_CLEANUP_CONFIG="${config_file}" \
    RUNNER_CLEANUP_TEST_CALLS="${calls_file}" \
    RUNNER_CLEANUP_LOG_DIR="${log_dir}" \
    RUNNER_CLEANUP_LOG_FILE="${log_file}" \
    DRY_RUN="${dry_run_value}" \
      bash "${case_dir}/run.sh"
  else
    RUNNER_CLEANUP_CONFIG="${config_file}" \
    RUNNER_CLEANUP_TEST_CALLS="${calls_file}" \
    RUNNER_CLEANUP_LOG_DIR="${log_dir}" \
    RUNNER_CLEANUP_LOG_FILE="${log_file}" \
      bash "${case_dir}/run.sh"
  fi

  assert_file_contains "${log_file}" 'runner-cleanup start'
  assert_file_contains "${log_file}" "config=${config_file}"
  assert_file_contains "${log_file}" 'DRY_RUN='
  assert_file_contains "${log_file}" 'ENABLE_IMAGE_CLEANUP='
  assert_file_contains "${log_file}" 'ENABLE_DOCKER_CACHE_CLEANUP='
  assert_file_contains "${log_file}" 'ENABLE_LOCAL_CACHE_CLEANUP='
  assert_file_contains "${log_file}" 'runner-cleanup end exit_code=0'
}

DEFAULT_CALLS="${TMP_DIR}/default.calls"
run_case "${TMP_DIR}/default" "" "${DEFAULT_CALLS}"

assert_file_contains "${DEFAULT_CALLS}" 'clean:1:7'
assert_file_contains "${DEFAULT_CALLS}" 'docker:1'
assert_file_contains "${DEFAULT_CALLS}" 'local:1'
assert_file_not_contains "${DEFAULT_CALLS}" 'unset'
assert_file_equals "${DEFAULT_CALLS}" $'clean:1:7\ndocker:1\nlocal:1'

REAL_CALLS="${TMP_DIR}/real.calls"
run_case "${TMP_DIR}/real" '0' "${REAL_CALLS}"

assert_file_contains "${REAL_CALLS}" 'clean:0:7'
assert_file_contains "${REAL_CALLS}" 'docker:0'
assert_file_contains "${REAL_CALLS}" 'local:0'
assert_file_equals "${REAL_CALLS}" $'clean:0:7\ndocker:0\nlocal:0'
