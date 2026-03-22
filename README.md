# Runner Cleanup

Chinese version: [`README.zh-CN.md`](README.zh-CN.md)

Shell scripts for keeping GitLab Runner hosts clean without touching GitLab or runner server settings.

## What it does

- Removes old Docker images and keeps the latest `KEEP_MAX_IMAGES` unique image IDs per repository.
- Runs GitLab Runner Docker cleanup for unused runner-managed containers and volumes.
- Scans and cleans host-based runner local cache under `runner-*` directories.

## Cleanup layers

`run.sh` can drive three independent cleanup layers:

- `ENABLE_IMAGE_CLEANUP=1`: run `clean.sh` to prune old Docker images.
- `ENABLE_DOCKER_CACHE_CLEANUP=1`: run `clear-docker-cache.sh` for runner-managed Docker garbage.
- `ENABLE_LOCAL_CACHE_CLEANUP=1`: run `clear-runner-local-cache.sh` for host-based `runner-*` cache/workspace data.

The Docker-facing cleanup and the host local-cache cleanup are different:

- Docker cleanup targets Docker objects managed by GitLab Runner, such as stopped containers and unused volumes.
- Local cache cleanup targets files under the runner cache directory on the host, especially `runner-*` workspaces and `*.tmp` directories.

## Local cache model

The local cache cleanup script treats data in three classes:

- `SAFE_TMP`: temporary `*.tmp` directories, safe to remove.
- `WORKSPACE_REBUILDABLE`: stale project workspaces under `runner-*`; removing them may cause archive re-extraction or a fresh clone/build, but does not delete archive cache.
- `ARCHIVE_CACHE`: `cache.zip` files. These are scanned and counted in the first version and are not deleted by default.

## Files

- `run.sh`: combined entrypoint.
- `clean.sh`: old Docker image cleanup.
- `clear-docker-cache.sh`: runner-managed Docker container and volume cleanup.
- `clear-runner-local-cache.sh`: host-based runner local cache scan and cleanup.
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
git clone https://github.com/yaoge123/runner-cleanup.git
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
| `KEEP_MAX_IMAGES` | `5` in `run.sh` | `clean.sh` | Raise or lower Docker image retention per repository. |
| `ENABLE_IMAGE_CLEANUP` | `1` in `run.sh` | `run.sh` -> `clean.sh` | Set to `0` if you do not want old Docker images removed. |
| `ENABLE_DOCKER_CACHE_CLEANUP` | `1` in `run.sh` | `run.sh` -> `clear-docker-cache.sh` | Set to `0` if you do not want runner-managed Docker objects pruned. |
| `ENABLE_LOCAL_CACHE_CLEANUP` | `1` in `run.sh` | `run.sh` -> `clear-runner-local-cache.sh` | Disable only if this host should skip local cache cleanup entirely. |
| `RUNNER_CACHE_DIR` | `/cache` | `clear-runner-local-cache.sh` | Change only when the runner host stores local cache under another allowlisted path. |
| `DRY_RUN` | `1` in `run.sh` and child scripts | `run.sh`, `clean.sh`, `clear-docker-cache.sh`, `clear-runner-local-cache.sh` | Set to `0` only after validating the full cleanup flow. |
| `VERBOSE` | `1` in `clear-runner-local-cache.sh` | `clear-runner-local-cache.sh` | Set to `0` if you want less scan detail in logs. |
| `ENABLE_TMP_CLEANUP` | `1` | `clear-runner-local-cache.sh` | Set to `0` to leave `*.tmp` directories untouched. |
| `ENABLE_WORKSPACE_CLEANUP` | `1` | `clear-runner-local-cache.sh` | Set to `0` to disable stale workspace deletion. |
| `ENABLE_ARCHIVE_CLEANUP` | `0` | `clear-runner-local-cache.sh` | Reserved for future use; current code scans and counts archive files only. |
| `TMP_MAX_AGE_DAYS` | `1` | `clear-runner-local-cache.sh` | Raise if tmp directories should survive longer before cleanup. |
| `WORKSPACE_MAX_AGE_DAYS` | `7` | `clear-runner-local-cache.sh` | Main stale threshold for workspace cleanup. |
| `ACTIVE_WINDOW_HOURS` | `48` | `clear-runner-local-cache.sh` | Increase if recently active trees should stay protected longer. |
| `TOP_N_LARGEST` | `20` | `clear-runner-local-cache.sh` | Adjust how many largest paths are shown in scan output. |
| `RUNNER_CLEANUP_CONFIG` | unset | `load-config.sh`, `run.sh` | Point to a specific config file instead of auto-discovery. |
| `RUNNER_CLEANUP_LOG_DIR` | `/var/log/runner-cleanup` | `run.sh` | Override when `/var/log/runner-cleanup` is not writable, such as local non-root tests. |
| `RUNNER_CLEANUP_LOG_FILE` | `/var/log/runner-cleanup/runner-cleanup.log` | `run.sh` | Override when a different log file path is required. |

### Internal script variables

These are implementation details, not normal operator settings:

| Variable | Produced by | Meaning |
| --- | --- | --- |
| `RUNNER_CLEANUP_LOADED_CONFIG` | `load-config.sh` | Absolute path of the config file actually loaded; `run.sh` writes it as `config=...` in logs. |
| `RUNNER_CLEANUP_LOGGING_INITIALIZED` | `run.sh` | Internal guard that prevents repeated bootstrap log setup. |
| `BOOTSTRAP_LOG_DIR` | `run.sh` | Temporary pre-config logging directory used before final config resolution. |
| `BOOTSTRAP_LOG_FILE` | `run.sh` | Temporary pre-config log file path used during early startup. |
| `FINAL_LOG_DIR` | `run.sh` | Final resolved log directory after config/env evaluation. |
| `FINAL_LOG_FILE` | `run.sh` | Final resolved log file after config/env evaluation. |

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

1. `clean.sh "${KEEP_MAX_IMAGES}"`
2. `clear-docker-cache.sh`
3. `clear-runner-local-cache.sh`

Each layer can be enabled or disabled independently.

## Docker cleanup variables

`run.sh`, `clean.sh`, and `clear-docker-cache.sh` use these Docker-related settings:

```bash
KEEP_MAX_IMAGES=5
ENABLE_IMAGE_CLEANUP=1
ENABLE_DOCKER_CACHE_CLEANUP=1
```

- `KEEP_MAX_IMAGES`: passed to `clean.sh` as a positional argument; for each Docker repository name, keep only the newest `KEEP_MAX_IMAGES` unique image IDs and remove older ones.
- `ENABLE_IMAGE_CLEANUP`: when `1`, run `clean.sh`; when `0`, skip old-image cleanup completely.
- `ENABLE_DOCKER_CACHE_CLEANUP`: when `1`, run `clear-docker-cache.sh`; when `0`, skip runner-managed Docker container/volume cleanup.

### `clean.sh`

- Enumerates Docker repositories with `docker images --format '{{.Repository}}'`.
- Works per repository, not globally across all images.
- Removes older image IDs and keeps the newest `KEEP_MAX_IMAGES` unique image IDs for each repository name.
- Uses `docker rmi -f`, so this layer is more aggressive than the local cache cleanup.

### `clear-docker-cache.sh`

Supported commands:

```bash
bash clear-docker-cache.sh prune-volumes
bash clear-docker-cache.sh prune
bash clear-docker-cache.sh space
bash clear-docker-cache.sh help
```

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
ENABLE_ARCHIVE_CLEANUP=0

TMP_MAX_AGE_DAYS=1
WORKSPACE_MAX_AGE_DAYS=7
ACTIVE_WINDOW_HOURS=48
TOP_N_LARGEST=20
```

## Safety model

- Only allowlisted cache roots are accepted: `/cache`, `/home/gitlab-runner/cache`, `/var/lib/gitlab-runner/cache`.
- The first version only cleans `runner-*` workspaces and `*.tmp` directories.
- `cache.zip` archive files are scanned and counted, but not removed by default.
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

Current deployment on the runner host uses these concrete paths:

- Cron entry: `/etc/cron.d/gitrunner`
- Wrapper script: `/home/yaoge/docker/runner-cleanup.sh`
- Deployed config: `/home/yaoge/docker/runner-cleanup.conf`
- Log file: `/var/log/runner-cleanup/runner-cleanup.log`

## Notes

- Run the scripts with permissions that can read and delete the target cache directories.
- File logging is handled by `run.sh`; cron no longer needs shell redirection for the normal case.
- A sample `logrotate` config is provided in `logrotate/runner-cleanup`.
- On the current runner host, install that sample as `/etc/logrotate.d/runner-cleanup` so `/var/log/runner-cleanup/runner-cleanup.log` does not grow without bound.
- `DRY_RUN=1` now protects all three cleanup layers; `clean.sh` and `clear-docker-cache.sh` print the Docker commands they would run instead of deleting anything.
- `run.sh` now logs `DRY_RUN` plus all three layer enable flags at startup so cron logs show the effective execution mode immediately.
- Removing workspace data can make the next job slower due to cache restore or rebuild.
- Removing archive cache is intentionally left disabled in the first version.
- `config=` in the log reflects the actual config file that was loaded, or `none` when no config file was found.

## Related

- [GitLab Runner Docker executor docs](https://docs.gitlab.com/runner/executors/docker.html#clear-the-docker-cache)
- [GitLab CI caching docs](https://docs.gitlab.com/ci/caching/)
