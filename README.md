# Runner Cleanup

Chinese version: [`README.zh-CN.md`](README.zh-CN.md)

Shell scripts for keeping GitLab Runner hosts clean without touching GitLab or runner server settings.

## What it does

- Adds a conservative image cleanup layer that removes dangling Docker images and stale tagged images.
- Optionally removes stale tagged Docker images that have not been used by CI jobs for `IMAGE_MAX_AGE_DAYS` days (31 by default). Requires the image usage tracker.
- Runs GitLab Runner Docker cleanup for unused runner-managed containers and volumes.
- Scans and cleans host-based runner local cache under `runner-*` directories.

## Cleanup layers

`run.sh` can drive three independent cleanup layers:

- `ENABLE_IMAGE_CLEANUP=1`: run dangling-only Docker image cleanup with `docker image prune -f`, then run stale tagged image cleanup via `clear-docker-cache.sh image-age` (only when `IMAGE_MAX_AGE_DAYS > 0`).
- `ENABLE_DOCKER_CACHE_CLEANUP=1`: run `clear-docker-cache.sh` for runner-managed Docker garbage.
- `ENABLE_LOCAL_CACHE_CLEANUP=1`: run `clear-runner-local-cache.sh` for host-based `runner-*` cache/workspace data.

The Docker-facing cleanup and the host local-cache cleanup are different:

- The image cleanup layer targets dangling Docker images (`<none>:<none>`) and stale tagged images that have not been used by CI jobs within `IMAGE_MAX_AGE_DAYS` days. It does not remove tagged images that are currently in use by any container or that have recorded CI usage within the window. Image usage data is collected by a separate `docker-image-tracker` systemd service.
- Docker cache cleanup targets Docker objects managed by GitLab Runner, such as stopped containers and unused volumes.
- Local cache cleanup targets files under the runner cache directory on the host, especially `runner-*` workspaces and `*.tmp` directories.

## Requirements

These scripts are intended for Linux GitLab Runner hosts with:

- Bash 4.0 or newer. The config loader uses Bash associative arrays.
- Docker CLI access for Docker cleanup layers. `clear-docker-cache.sh` requires Docker client and daemon API `1.25` or newer.
- `python3` for host local-cache scanning.
- GNU-style userland tools used by the scripts, including `awk`, `find`, `sort`, `stat -c`, and either `realpath -m` or `readlink -m`.
- `docker-image-tracker` systemd service (included) running on the host. This service listens to Docker container start events to record which images are used by CI jobs. Without it, `image-age` cleanup will skip with a warning.

Docker API versions older than `1.25` are not treated as a supported compatibility target. If a runner host is that old, disable `ENABLE_IMAGE_CLEANUP` and `ENABLE_DOCKER_CACHE_CLEANUP` for that host or upgrade Docker before enabling Docker cleanup. Host local-cache cleanup can still be used independently when its own requirements are met.

If only the legacy `clean.sh` helper is used manually, Docker CLI access plus the standard shell tools are sufficient.

## Image Usage Tracker

`track-docker-image-usage.py` is a Python daemon that subscribes to Docker `container:start` events from GitLab Runner managed containers and records which image digests have been used by CI jobs.

### How it works

1. Listens to `docker events --filter event=start --filter type=container --filter label=com.gitlab.gitlab-runner.managed=true` in real time.
2. Each `container:start` event provides an image digest (sha256), a Unix timestamp, the CI job ID, and the project path.
3. Records these per-digest to `/var/lib/runner-cleanup/image-usage.json`, deduplicating by digest key so the file does not grow without bound.
4. The `image-age` cleanup reads this data, maps digests to image tags via `docker images --no-trunc` at cleanup time, and identifies tagged images that have not been used within `IMAGE_MAX_AGE_DAYS`.

### Deployment

```bash
cp systemd/docker-image-tracker.service /etc/systemd/system/
# Adjust the ExecStart path in the unit file to match your installation directory
systemctl daemon-reload
systemctl enable --now docker-image-tracker
```

The tracker must be running for at least `IMAGE_MAX_AGE_DAYS` before the `image-age` cleanup can make accurate decisions. Until then, images with no recorded usage are skipped.

## Local cache model

The local cache cleanup script treats data in three classes:

- `SAFE_TMP`: temporary `*.tmp` directories, safe to remove.
- `WORKSPACE_REBUILDABLE`: stale project workspaces under `runner-*`; removing them may cause archive re-extraction or a fresh clone/build, but does not delete archive cache.
- `ARCHIVE_CACHE`: `cache.zip` files. When `ENABLE_ARCHIVE_CLEANUP=1`, archives older than `ARCHIVE_MAX_AGE_DAYS` (by mtime) are deleted.

## Files

- `run.sh`: combined entrypoint.
- `clean.sh`: legacy per-repository old Docker image cleanup helper; not used by `run.sh`.
- `clear-docker-cache.sh`: runner-managed Docker container and volume cleanup.
- `clear-runner-local-cache.sh`: host-based runner local cache scan and cleanup.
- `track-docker-image-usage.py`: Docker image usage tracker that records which images are used by CI jobs.
- `systemd/docker-image-tracker.service`: systemd unit file for the image usage tracker.
- `logrotate/runner-cleanup`: sample logrotate policy for `/var/log/runner-cleanup/runner-cleanup.log`.
- `test/run-logging-smoke.sh`: smoke test for built-in file logging.
- `test/run-logging-behavior.sh`: verifies log path selection, config loading, and exit logging behavior.
- `test/run-dry-run-behavior.sh`: verifies that `run.sh` passes a unified `DRY_RUN` mode to all three cleanup layers.
- `test/docker-dry-run-behavior.sh`: verifies Docker image/container cleanup does not perform real deletion when `DRY_RUN=1`.
- `test/clear-runner-local-cache-behavior.sh`: verifies active-window and local-cache scan behavior.
- `runner-cleanup.conf.example`: sample configuration file.

## Usage

Clone the repository and run scripts locally on the runner host.

```bash
git clone https://github.com/nh4ttruong/runner-cleanup.git
cd runner-cleanup
cp runner-cleanup.conf.example runner-cleanup.conf
bash run.sh
```

## Configuration file

The recommended way is to put long-lived settings in `runner-cleanup.conf`.

Load order:

- `RUNNER_CLEANUP_CONFIG=/path/to/file` if set.
- `runner-cleanup.conf` in the repository directory.
- `./runner-cleanup.conf` in the current working directory.

Environment variables are still supported and override values from the config file for one-off runs.

## Configuration reference

The settings below are the ones operators are expected to change. They come from `runner-cleanup.conf.example`, from explicit environment overrides, or from the defaults inside `run.sh` and `clear-runner-local-cache.sh`.

### User-facing settings

| Variable | Default | Used by | When to change |
| --- | --- | --- | --- |
| `KEEP_MAX_IMAGES` | `5` in `run.sh` | `clean.sh` manual use only | Legacy per-repository image retention setting; `run.sh` no longer uses it. |
| `ENABLE_IMAGE_CLEANUP` | `1` in `run.sh` | `run.sh` -> `clear-docker-cache.sh image-prune` and `image-age` | Set to `0` if you do not want dangling or stale tagged Docker images removed. |
| `IMAGE_MAX_AGE_DAYS` | `31` in `run.sh` | `run.sh` -> `clear-docker-cache.sh image-age` | Stale threshold for tagged image cleanup (only when `ENABLE_IMAGE_CLEANUP=1`). Set to `0` to disable. Requires the image usage tracker to be running. |
| `ENABLE_DOCKER_CACHE_CLEANUP` | `1` in `run.sh` | `run.sh` -> `clear-docker-cache.sh` | Set to `0` if you do not want runner-managed Docker objects pruned. |
| `ENABLE_LOCAL_CACHE_CLEANUP` | `1` in `run.sh` | `run.sh` -> `clear-runner-local-cache.sh` | Disable only if this host should skip local cache cleanup entirely. |
| `RUNNER_CACHE_DIR` | `/cache` | `clear-runner-local-cache.sh` | Change only when the runner host stores local cache under another allowlisted path. |
| `DRY_RUN` | `1` in `run.sh` and child scripts | `run.sh`, `clean.sh`, `clear-docker-cache.sh`, `clear-runner-local-cache.sh` | Set to `0` only after validating the full cleanup flow. |
| `VERBOSE` | `1` in `clear-runner-local-cache.sh` | `clear-runner-local-cache.sh` | Set to `0` if you want less scan detail in logs. |
| `ENABLE_TMP_CLEANUP` | `1` | `clear-runner-local-cache.sh` | Set to `0` to leave `*.tmp` directories untouched. |
| `ENABLE_WORKSPACE_CLEANUP` | `1` | `clear-runner-local-cache.sh` | Set to `0` to disable stale workspace deletion. |
| `ENABLE_ARCHIVE_CLEANUP` | `1` | `clear-runner-local-cache.sh` | Delete `cache.zip` files older than `ARCHIVE_MAX_AGE_DAYS`. Set to `0` to disable. |
| `TMP_MAX_AGE_DAYS` | `1` | `clear-runner-local-cache.sh` | Raise if tmp directories should survive longer before cleanup. |
| `WORKSPACE_MAX_AGE_DAYS` | `7` | `clear-runner-local-cache.sh` | Main stale threshold for workspace cleanup. |
| `ARCHIVE_MAX_AGE_DAYS` | `30` | `clear-runner-local-cache.sh` | Retention period for `cache.zip` archives; only effective when `ENABLE_ARCHIVE_CLEANUP=1`. |
| `TOP_N_LARGEST` | `10` | `clear-runner-local-cache.sh` | Adjust how many largest paths are shown in scan output. |
| `RUNNER_CLEANUP_CONFIG` | unset | `load-config.sh`, `run.sh` | Point to a specific config file instead of auto-discovery. |
| `RUNNER_CLEANUP_LOG_DIR` | `/var/log/runner-cleanup` | `run.sh` | Override when `/var/log/runner-cleanup` is not writable, such as local non-root tests. |
| `RUNNER_CLEANUP_LOG_FILE` | `/var/log/runner-cleanup/runner-cleanup.log` | `run.sh` | Override when a different log file path is required. |

### Internal script variables

These are implementation details, not normal operator settings:

| Variable | Produced by | Meaning |
| --- | --- | --- |
| `RUNNER_CLEANUP_LOADED_CONFIG` | `load-config.sh` | Absolute path of the config file actually loaded; `run.sh` writes it as `config=...` in logs. |
| `RUNNER_CLEANUP_LOGGING_INITIALIZED` | `run.sh` | Internal guard that prevents repeated bootstrap log setup. |

Do not put the internal variables above in `runner-cleanup.conf` unless you are debugging the scripts themselves.

Built-in file logging defaults to:

- `RUNNER_CLEANUP_LOG_DIR=/var/log/runner-cleanup`
- `RUNNER_CLEANUP_LOG_FILE=/var/log/runner-cleanup/runner-cleanup.log`

You can install the sample rotation policy from `logrotate/runner-cleanup` to avoid unbounded log growth.

For local non-root runs, export `RUNNER_CLEANUP_LOG_DIR` and `RUNNER_CLEANUP_LOG_FILE` before invoking `run.sh` if `/var/log/runner-cleanup` is not writable.

Example:

```bash
cp runner-cleanup.conf.example runner-cleanup.conf
vim runner-cleanup.conf
bash run.sh
```

## Default behavior

`run.sh` executes local scripts from the repository instead of fetching remote scripts.

Defaults:

```bash
KEEP_MAX_IMAGES=5
ENABLE_IMAGE_CLEANUP=1
ENABLE_DOCKER_CACHE_CLEANUP=1
ENABLE_LOCAL_CACHE_CLEANUP=1
```

`run.sh` executes cleanup in this order:

1. `clear-docker-cache.sh image-prune`
2. `clear-docker-cache.sh image-age` (only when `IMAGE_MAX_AGE_DAYS > 0`)
3. `clear-docker-cache.sh`
4. `clear-runner-local-cache.sh`

Each layer can be enabled or disabled independently.

## Docker cleanup variables

`run.sh` and `clear-docker-cache.sh` use these Docker-related settings:

```bash
KEEP_MAX_IMAGES=5
ENABLE_IMAGE_CLEANUP=1
ENABLE_DOCKER_CACHE_CLEANUP=1
IMAGE_MAX_AGE_DAYS=31
```

- `KEEP_MAX_IMAGES`: legacy setting for manual `clean.sh` use only. `run.sh` does not use it.
- `ENABLE_IMAGE_CLEANUP`: when `1`, run `clear-docker-cache.sh image-prune` and `image-age` (if `IMAGE_MAX_AGE_DAYS > 0`); when `0`, skip both.
- `ENABLE_DOCKER_CACHE_CLEANUP`: when `1`, run `clear-docker-cache.sh`; when `0`, skip.
- `IMAGE_MAX_AGE_DAYS`: when `> 0` and `ENABLE_IMAGE_CLEANUP=1`, run `clear-docker-cache.sh image-age` after image-prune to remove stale tagged images. Requires the image usage tracker.

The `ENABLE_IMAGE_CLEANUP` layer is intentionally conservative: it only removes dangling images, equivalent to `docker image prune -f`, and stale tagged images that have not been used by CI jobs for `IMAGE_MAX_AGE_DAYS` days. This layer never runs `docker image prune -a`, `docker system prune`, or `docker system prune -a`, and it does not remove tagged images currently in use or with recent CI usage.

The `ENABLE_DOCKER_CACHE_CLEANUP` layer is separate and keeps the existing runner-managed Docker garbage cleanup behavior in `clear-docker-cache.sh`. When enabled, that layer still invokes Docker system prune commands filtered by the GitLab Runner managed label.

### `clean.sh`

- This is a legacy helper and is not called by `run.sh`.
- Enumerates Docker repositories with `docker images --format '{{.Repository}}'`.
- Works per repository, not globally across all images.
- Removes older image IDs and keeps the newest `KEEP_MAX_IMAGES` unique image IDs for each repository name.
- Uses `docker rmi -f`, so this layer is more aggressive than the local cache cleanup.

### `clear-docker-cache.sh`

Supported commands:

```bash
bash clear-docker-cache.sh prune-volumes
bash clear-docker-cache.sh image-prune
bash clear-docker-cache.sh image-age
bash clear-docker-cache.sh prune
bash clear-docker-cache.sh space
bash clear-docker-cache.sh help
```

- `image-prune`: remove dangling Docker images only, using `docker image prune -f`; tagged images are never removed.
- `image-age`: remove tagged Docker images that have not been used by CI jobs for `IMAGE_MAX_AGE_DAYS` days. Reads usage data from `/var/lib/runner-cleanup/image-usage.json` (produced by the tracker). Never removes images currently in use by any container, images with zero recorded usage, or dangling images (handled by image-prune).
- `prune-volumes`: remove unused runner-managed containers and volumes.
- `prune`: remove unused runner-managed containers only.
- `space`: show Docker disk usage.
- `help`: show usage.

`run.sh` invokes `clear-docker-cache.sh` with no arguments, so the default action is `prune-volumes`.

This script only targets Docker objects carrying the GitLab Runner managed label:

```text
com.gitlab.gitlab-runner.managed=true
```

That keeps it focused on runner-created Docker resources instead of arbitrary user containers.

Manual execution now defaults to observation mode: `run.sh` enables all cleanup layers by default, and `DRY_RUN=1` is exported to image cleanup, Docker cleanup, and local cache cleanup together. So the safest first check is simply:

```bash
bash run.sh
```

To execute real `runner-*` cleanup manually while preserving the 48-hour activity window:

```bash
DRY_RUN=0 bash run.sh
```

## Local cache cleanup variables

`clear-runner-local-cache.sh` supports these environment variables:

```bash
RUNNER_CACHE_DIR=/cache
DRY_RUN=1
VERBOSE=1

RUNNER_CLEANUP_LOG_DIR=/var/log/runner-cleanup
RUNNER_CLEANUP_LOG_FILE=/var/log/runner-cleanup/runner-cleanup.log

ENABLE_TMP_CLEANUP=1
ENABLE_WORKSPACE_CLEANUP=1
ENABLE_ARCHIVE_CLEANUP=1

TMP_MAX_AGE_DAYS=1
WORKSPACE_MAX_AGE_DAYS=7
ARCHIVE_MAX_AGE_DAYS=30
TOP_N_LARGEST=10
```

## Safety model

- Only allowlisted cache roots are accepted: `/cache`, `/home/gitlab-runner/cache`, `/var/lib/gitlab-runner/cache`.
- The first version only cleans `runner-*` workspaces and `*.tmp` directories.
- `cache.zip` archive files are scanned and counted; when `ENABLE_ARCHIVE_CLEANUP=1`, archives with mtime older than `ARCHIVE_MAX_AGE_DAYS` are deleted.
- `protected` and unprotected workspaces are handled separately.
- A workspace is treated as active when the newest file or directory mtime anywhere under that tree is within the active window.

## Cron example

For cron, keep the command plain and let `runner-cleanup.conf` decide whether the host runs in dry-run or real-cleanup mode:

```cron
0 3 * * * cd /path/to/runner-cleanup && bash run.sh
```

Recommended model:

- Manual execution uses script defaults, so `bash run.sh` is dry-run observation across all cleanup layers by default.
- Cron also runs plain `bash run.sh`; the deployed `runner-cleanup.conf` on that host determines the actual mode.
- On a production runner host, review manual dry-run output first, then set `DRY_RUN=0` in the deployed config when you are ready for real cleanup.

## Notes

- Run the scripts with permissions that can read and delete the target cache directories.
- File logging is handled by `run.sh`; cron no longer needs shell redirection for the normal case.
- A sample `logrotate` config is provided in `logrotate/runner-cleanup`.
- Install the sample logrotate config through your system's normal logrotate configuration path so the cleanup log does not grow without bound.
- `DRY_RUN=1` now protects all three cleanup layers; `clean.sh` and `clear-docker-cache.sh` print the Docker commands they would run instead of deleting anything.
- `run.sh` now logs `DRY_RUN` plus all three layer enable flags at startup so cron logs show the effective execution mode immediately.
- Removing workspace data can make the next job slower due to cache restore or rebuild.
- Removing archive cache (`cache.zip`) is enabled by default (`ENABLE_ARCHIVE_CLEANUP=1`). Only archives older than `ARCHIVE_MAX_AGE_DAYS` (default 30) are removed. Deleting an archive causes a real CI cache miss for that key.
- `config=` in the log reflects the actual config file that was loaded, or `none` when no config file was found.

## Related

- [GitLab Runner Docker executor docs](https://docs.gitlab.com/runner/executors/docker.html#clear-the-docker-cache)
- [GitLab CI caching docs](https://docs.gitlab.com/ci/caching/)
