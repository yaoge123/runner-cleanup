#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

DOCKER_LOG="${TMP_DIR}/docker.log"
OUTPUT_LOG="${TMP_DIR}/output.log"

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

mkdir -p "${TMP_DIR}/bin"

cat > "${TMP_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RUNNER_CLEANUP_TEST_DOCKER_LOG}"

case "$*" in
  "images --format {{.Repository}}")
    printf 'repo1\n'
    ;;
  "images --format {{.ID}} --filter=reference=repo1")
    printf 'img-new\nimg-new\nimg-old\n'
    ;;
  "version --format {{.Client.APIVersion}}")
    printf '%s\n' "${RUNNER_CLEANUP_TEST_DOCKER_API_VERSION:-1.43}"
    ;;
  "version --format {{.Client.Version}}")
    printf '%s\n' "${RUNNER_CLEANUP_TEST_DOCKER_CLIENT_VERSION:-24.0.0}"
    ;;
  "version --format {{.Server.MinAPIVersion}}")
    printf '%s\n' "${RUNNER_CLEANUP_TEST_DOCKER_MIN_API_VERSION:-1.24}"
    ;;
  "ps -a -q --filter=status=exited --filter=status=dead --filter=label=com.gitlab.gitlab-runner.managed=true")
    printf 'container-1\ncontainer-2\n'
    ;;
  "system df")
    printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\n'
    ;;
  "image ls --filter dangling=true --format {{.Repository}}:{{.Tag}} {{.ID}}")
    printf '<none>:<none> dangling-1\n'
    ;;
esac
EOF

chmod +x "${TMP_DIR}/bin/docker"

: > "${DOCKER_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=1 \
  bash "${REPO_DIR}/clean.sh" > "${OUTPUT_LOG}" 2>&1
clean_missing_arg_exit_code=$?
set -e

if [ "${clean_missing_arg_exit_code}" -eq 0 ]; then
  printf 'clean.sh without KEEP_MAX_IMAGES should fail\n' >&2
  exit 1
fi

assert_file_contains "${OUTPUT_LOG}" 'Usage:'
assert_file_contains "${OUTPUT_LOG}" 'KEEP_MAX_IMAGES'

PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=1 \
  bash "${REPO_DIR}/clean.sh" 1 > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'Would remove 1 old image(s) of repository: repo1'
assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: docker rmi -f img-old'
assert_file_not_contains "${OUTPUT_LOG}" 'img-new'
assert_file_not_contains "${DOCKER_LOG}" 'rmi -f'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" prune-volumes > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: env DOCKER_API_VERSION=1.41 docker system prune --volumes -af --filter label=com.gitlab.gitlab-runner.managed=true'
assert_file_not_contains "${DOCKER_LOG}" 'system prune'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: env DOCKER_API_VERSION=1.41 docker system prune --volumes -af --filter label=com.gitlab.gitlab-runner.managed=true'
assert_file_not_contains "${OUTPUT_LOG}" 'Usage:'
assert_file_not_contains "${DOCKER_LOG}" 'system prune'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" RUNNER_CLEANUP_TEST_DOCKER_API_VERSION='1.52' RUNNER_CLEANUP_TEST_DOCKER_MIN_API_VERSION='1.44' DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" prune-volumes > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: env DOCKER_API_VERSION=1.52 docker system prune --volumes -af --filter label=com.gitlab.gitlab-runner.managed=true'
assert_file_not_contains "${OUTPUT_LOG}" 'DOCKER_API_VERSION=1.41'
assert_file_not_contains "${DOCKER_LOG}" 'system prune'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" image-prune > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'Check and remove dangling Docker images only.'
assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: docker image prune -f'
assert_file_contains "${DOCKER_LOG}" 'image ls --filter dangling=true'
assert_file_not_contains "${OUTPUT_LOG}" 'system prune'
assert_file_not_contains "${OUTPUT_LOG}" 'image prune -a'
assert_file_not_contains "${OUTPUT_LOG}" 'prune -af'
assert_file_not_contains "${DOCKER_LOG}" 'image prune'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=0 \
  bash "${REPO_DIR}/clear-docker-cache.sh" image-prune > "${OUTPUT_LOG}"

assert_file_contains "${DOCKER_LOG}" 'image prune -f'
assert_file_not_contains "${DOCKER_LOG}" 'system prune'
assert_file_not_contains "${DOCKER_LOG}" 'image prune -a'
assert_file_not_contains "${DOCKER_LOG}" 'prune -af'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" RUNNER_CLEANUP_TEST_DOCKER_CLIENT_VERSION='17.05.0' DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" prune > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: docker rm container-1 container-2'
assert_file_not_contains "${DOCKER_LOG}" 'rm container-1'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" RUNNER_CLEANUP_TEST_DOCKER_CLIENT_VERSION='17.03.0' DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" prune-volumes > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: docker rm -v container-1 container-2'
assert_file_not_contains "${DOCKER_LOG}" 'rm -v container-1'

: > "${DOCKER_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" typo-command > "${OUTPUT_LOG}" 2>&1
invalid_exit_code=$?
set -e

if [ "${invalid_exit_code}" -eq 0 ]; then
  printf 'invalid clear-docker-cache command should fail\n' >&2
  exit 1
fi

assert_file_contains "${OUTPUT_LOG}" 'Usage:'

# --- image-age tests ---

cat > "${TMP_DIR}/bin/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RUNNER_CLEANUP_TEST_DOCKER_LOG}"

case "$*" in
  "version --format {{.Client.APIVersion}}")
    printf '%s\n' "${RUNNER_CLEANUP_TEST_DOCKER_API_VERSION:-1.43}"
    ;;
  "version --format {{.Client.Version}}")
    printf '%s\n' "${RUNNER_CLEANUP_TEST_DOCKER_CLIENT_VERSION:-24.0.0}"
    ;;
  "version --format {{.Server.MinAPIVersion}}")
    printf '%s\n' "${RUNNER_CLEANUP_TEST_DOCKER_MIN_API_VERSION:-1.24}"
    ;;
  "ps -a -q --filter=status=exited --filter=status=dead --filter=label=com.gitlab.gitlab-runner.managed=true")
    printf 'container-1\ncontainer-2\n'
    ;;
  "system df")
    printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\n'
    ;;
  "image ls --filter dangling=true --format {{.Repository}}:{{.Tag}} {{.ID}}")
    printf '<none>:<none> dangling-1\n'
    ;;
  "images "*)
    if printf '%s\n' "$*" | grep -q "no-trunc"; then
      printf 'sha256:aaa\tpython:3.11\n'
      printf 'sha256:aaa\tdocker.example.com/library/python:3.11\n'
      printf 'sha256:bbb\tnode:22\n'
      printf 'sha256:ccc\tubuntu:20.04\n'
      printf 'sha256:ddd\tnode:18\n'
    elif printf '%s\n' "$*" | grep -q "Format";
    then
      :
    fi
    ;;
  "ps -a --format {{.Image}}")
    printf 'node:22\n'
    ;;
  "image prune -f")
    printf 'deleted: sha256:xxx\n'
    ;;
  "rmi python:3.11")
    printf 'Untagged: python:3.11\n'
    ;;
  "rmi node:18")
    printf 'Untagged: node:18\n'
    ;;
esac
DOCKEREOF

chmod +x "${TMP_DIR}/bin/docker"

cat > "${TMP_DIR}/image-usage.json" <<'JSONEOF'
{"sha256:aaa": {"last_used": 1700000000, "usage_count": 42},
 "sha256:bbb": {"last_used": 1778000000, "usage_count": 10},
 "sha256:ccc": {"last_used": 1700000000, "usage_count": 0},
 "sha256:ddd": {"last_used": 1700000000, "usage_count": 5}}
JSONEOF

# Test: dry-run with IMAGE_MAX_AGE_DAYS=31
: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" \
  DRY_RUN=1 IMAGE_MAX_AGE_DAYS=31 IMAGE_USAGE_STATE="${TMP_DIR}/image-usage.json" \
  bash "${REPO_DIR}/clear-docker-cache.sh" image-age > "${OUTPUT_LOG}"

assert_file_not_contains "${OUTPUT_LOG}" 'node:22'
assert_file_not_contains "${OUTPUT_LOG}" 'ubuntu:20.04'
assert_file_contains "${OUTPUT_LOG}" 'python:3.11'
assert_file_contains "${OUTPUT_LOG}" 'node:18'
assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1'
assert_file_not_contains "${DOCKER_LOG}" 'rmi'

# Test: real mode deletes only eligible candidates
: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" \
  DRY_RUN=0 IMAGE_MAX_AGE_DAYS=31 IMAGE_USAGE_STATE="${TMP_DIR}/image-usage.json" \
  bash "${REPO_DIR}/clear-docker-cache.sh" image-age > "${OUTPUT_LOG}"

assert_file_contains "${DOCKER_LOG}" 'rmi python:3.11'
assert_file_contains "${DOCKER_LOG}" 'rmi node:18'
assert_file_not_contains "${DOCKER_LOG}" 'rmi node:22'
assert_file_not_contains "${DOCKER_LOG}" 'rmi ubuntu:20.04'

# Test: no eligible candidates
cat > "${TMP_DIR}/image-usage.json" <<'JSONEOF'
{"sha256:bbb": {"last_used": 1778000000, "usage_count": 10}}
JSONEOF

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" \
  DRY_RUN=0 IMAGE_MAX_AGE_DAYS=31 IMAGE_USAGE_STATE="${TMP_DIR}/image-usage.json" \
  bash "${REPO_DIR}/clear-docker-cache.sh" image-age > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'No stale tagged images found'
