# Runner Cleanup

Shell scripts for keeping GitLab Runner hosts clean without touching GitLab or runner server settings.

## What it does

- Removes old Docker images and keeps the latest `KEEP_MAX_IMAGES` entries per repository.
- Runs GitLab Runner Docker cleanup for unused runner-managed containers and volumes.
- Scans and cleans host-based runner local cache under `runner-*` directories.

## Local cache model

The local cache cleanup script treats data in three classes:

- `SAFE_TMP`: temporary `*.tmp` directories, safe to remove.
- `WORKSPACE_REBUILDABLE`: stale project workspaces under `runner-*`; removing them may cause archive re-extraction or a fresh clone/build, but does not delete archive cache.
- `ARCHIVE_CACHE`: `cache.zip` files. These are reported only in the first version and are not deleted by default.

## Files

- `run.sh`: combined entrypoint.
- `clean.sh`: old Docker image cleanup.
- `clear-docker-cache.sh`: runner-managed Docker container and volume cleanup.
- `clear-runner-local-cache.sh`: host-based runner local cache scan and cleanup.
- `logrotate/runner-cleanup`: sample logrotate policy for `/var/log/runner-cleanup/runner-cleanup.log`.
- `test/run-logging-smoke.sh`: smoke test for built-in file logging.
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

Built-in file logging defaults to:

- `RUNNER_CLEANUP_LOG_DIR=/var/log/runner-cleanup`
- `RUNNER_CLEANUP_LOG_FILE=/var/log/runner-cleanup/runner-cleanup.log`

You can install the sample rotation policy from `logrotate/runner-cleanup` to avoid unbounded log growth.

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
ENABLE_LOCAL_CACHE_CLEANUP=0
```

To enable runner local cache cleanup in dry-run mode:

```bash
bash run.sh
```

To execute real `runner-*` cleanup while preserving the 48-hour activity window:

```bash
DRY_RUN=0 bash run.sh
```

If you only want a temporary override without editing the config file:

```bash
DRY_RUN=0 MAX_DELETE_GB_PER_RUN=20 bash run.sh
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
ENABLE_DUPLICATE_WORKSPACE_REPORT=1
ENABLE_DUPLICATE_WORKSPACE_CLEANUP=1
ENABLE_ARCHIVE_CLEANUP=0

TMP_MAX_AGE_DAYS=1
WORKSPACE_MAX_AGE_DAYS=7
ACTIVE_WINDOW_HOURS=48
KEEP_WORKSPACE_COPIES=1
MAX_DELETE_GB_PER_RUN=10
TOP_N_LARGEST=20
```

## Safety model

- Only allowlisted cache roots are accepted: `/cache`, `/home/gitlab-runner/cache`, `/var/lib/gitlab-runner/cache`.
- The first version only cleans `runner-*` workspaces and `*.tmp` directories.
- `cache.zip` archive files are scanned and counted, but not removed by default.
- `protected` and unprotected workspaces are handled separately.
- Paths updated in the last 48 hours are preserved by default.
- Cleanup is capped by `MAX_DELETE_GB_PER_RUN`.

## Cron example

Start with dry-run for observation:

```bash
0 * * * * cd /path/to/runner-cleanup && bash run.sh
```

After validation, enable real cleanup:

```bash
0 3 * * * cd /path/to/runner-cleanup && DRY_RUN=0 bash run.sh
```

## Notes

- Run the scripts with permissions that can read and delete the target cache directories.
- File logging is handled by `run.sh`; cron no longer needs shell redirection for the normal case.
- A sample `logrotate` config is provided in `logrotate/runner-cleanup`.
- Removing workspace data can make the next job slower due to cache restore or rebuild.
- Removing archive cache is intentionally left disabled in the first version.

## Related

- [GitLab Runner Docker executor docs](https://docs.gitlab.com/runner/executors/docker.html#clear-the-docker-cache)
- [GitLab CI caching docs](https://docs.gitlab.com/ci/caching/)
