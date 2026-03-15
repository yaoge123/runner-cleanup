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
    printf 'img-new\nimg-old\n'
    ;;
  "version --format {{.Client.APIVersion}}")
    printf '%s\n' "${RUNNER_CLEANUP_TEST_DOCKER_API_VERSION:-1.43}"
    ;;
  "version --format {{.Client.Version}}")
    printf '%s\n' "${RUNNER_CLEANUP_TEST_DOCKER_CLIENT_VERSION:-24.0.0}"
    ;;
  "ps -a -q --filter=status=exited --filter=status=dead --filter=label=com.gitlab.gitlab-runner.managed=true")
    printf 'container-1\ncontainer-2\n'
    ;;
  "system df")
    printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\n'
    ;;
esac
EOF

chmod +x "${TMP_DIR}/bin/docker"

PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=1 \
  bash "${REPO_DIR}/clean.sh" 1 > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'Would remove 1 old image(s) of repository: repo1'
assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: docker rmi -f img-old'
assert_file_not_contains "${DOCKER_LOG}" 'rmi -f'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" prune-volumes > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: env DOCKER_API_VERSION=1.41 docker system prune --volumes -af --filter label=com.gitlab.gitlab-runner.managed=true'
assert_file_not_contains "${DOCKER_LOG}" 'system prune'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" RUNNER_CLEANUP_TEST_DOCKER_CLIENT_VERSION='17.05.0' DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" prune > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: docker rm container-1'
assert_file_contains "${OUTPUT_LOG}" 'container-2'
assert_file_not_contains "${DOCKER_LOG}" 'rm container-1'

: > "${DOCKER_LOG}"
PATH="${TMP_DIR}/bin:${PATH}" RUNNER_CLEANUP_TEST_DOCKER_LOG="${DOCKER_LOG}" RUNNER_CLEANUP_TEST_DOCKER_CLIENT_VERSION='17.03.0' DRY_RUN=1 \
  bash "${REPO_DIR}/clear-docker-cache.sh" prune-volumes > "${OUTPUT_LOG}"

assert_file_contains "${OUTPUT_LOG}" 'DRY_RUN=1 would run: docker rm -v container-1'
assert_file_contains "${OUTPUT_LOG}" 'container-2'
assert_file_not_contains "${DOCKER_LOG}" 'rm -v container-1'
