# Runner Cleanup

英文版：[`README.md`](README.md)

用于清理 GitLab Runner 主机的 Shell 脚本集合，不修改 GitLab 或 Runner 服务端配置。

## 功能概览

- 增加一个保守的镜像清理层，删除 dangling Docker 镜像和长期未使用的 tagged 镜像。
- 可选地删除超过 `IMAGE_MAX_AGE_DAYS` 天（默认 31 天）未被 CI job 使用过的 tagged Docker 镜像。需要镜像使用追踪器运行。
- 执行 GitLab Runner 管理的 Docker 容器与卷清理。
- 扫描并清理主机上 `runner-*` 目录下的本地 Runner 缓存。

## 清理层次

`run.sh` 可以驱动三层彼此独立的清理逻辑：

- `ENABLE_IMAGE_CLEANUP=1`：通过 `docker image prune -f` 执行只针对 dangling image 的镜像清理，然后通过 `clear-docker-cache.sh image-age` 清理过期 tagged 镜像（仅当 `IMAGE_MAX_AGE_DAYS > 0` 时）。
- `ENABLE_DOCKER_CACHE_CLEANUP=1`：执行 `clear-docker-cache.sh` 清理 Runner 管理的 Docker 垃圾。
- `ENABLE_LOCAL_CACHE_CLEANUP=1`：执行 `clear-runner-local-cache.sh` 清理主机上的 `runner-*` 缓存/工作区数据。

Docker 侧清理与主机本地缓存清理不是一回事：

- 镜像清理层针对 dangling Docker image（`<none>:<none>`）和超过 `IMAGE_MAX_AGE_DAYS` 天未被 CI job 使用过的 tagged 镜像。不会删除正在被容器使用的镜像或在窗口内有 CI 使用记录的镜像。镜像使用数据由独立的 `docker-image-tracker` systemd 服务收集。
- Docker cache 清理针对 GitLab Runner 管理的 Docker 对象，例如已停止容器和未使用卷。
- 本地缓存清理针对主机缓存目录里的文件，尤其是 `runner-*` 工作区和 `*.tmp` 目录。

## 运行要求

这些脚本面向 Linux GitLab Runner 主机，要求：

- Bash 4.0 或更新版本。配置加载器使用 Bash associative arrays。
- Docker 清理层需要可访问 Docker CLI。`clear-docker-cache.sh` 要求 Docker client 和 daemon API 都不低于 `1.25`。
- 主机本地缓存扫描需要 `python3`。
- GNU 风格基础工具，包括 `awk`、`find`、`sort`、`stat -c`，以及 `realpath -m` 或 `readlink -m` 二者之一。
- 主机上需要运行 `docker-image-tracker` systemd 服务（已包含）。该服务监听 Docker 容器启动事件，记录哪些镜像被 CI job 使用过。缺少该服务时，`image-age` 清理会输出警告并跳过。

Docker API 低于 `1.25` 不作为受支持的兼容目标。如果某台 runner host 的 Docker 版本低到这种程度，应当为该主机关闭 `ENABLE_IMAGE_CLEANUP` 和 `ENABLE_DOCKER_CACHE_CLEANUP`，或先升级 Docker 再启用 Docker 清理。本地主机缓存清理在满足自身依赖时仍可独立使用。

如果只手工使用旧的 `clean.sh` 辅助脚本，只需要 Docker CLI 和标准 shell 工具。

## 镜像使用追踪器

`track-docker-image-usage.py` 是一个 Python 守护进程，订阅 GitLab Runner 管理容器的 Docker `container:start` 事件，记录 CI job 使用了哪些镜像摘要。

### 工作原理

1. 实时监听 `docker events --filter event=start --filter type=container --filter label=com.gitlab.gitlab-runner.managed=true`。
2. 每次 `container:start` 事件提供镜像摘要（sha256）、Unix 时间戳、CI job ID 和项目路径。
3. 以摘要为键记录到 `/var/lib/runner-cleanup/image-usage.json`，去重存储，文件不会无限增长。
4. `image-age` 清理读取该数据，在清理时通过 `docker images --no-trunc` 将摘要映射为镜像 tag，识别出在 `IMAGE_MAX_AGE_DAYS` 天内未被使用的 tagged 镜像。

### 部署

```bash
cp systemd/docker-image-tracker.service /etc/systemd/system/
# 在单元文件中调整 ExecStart 路径以匹配你的安装目录
systemctl daemon-reload
systemctl enable --now docker-image-tracker
```

追踪器需要运行至少 `IMAGE_MAX_AGE_DAYS` 天后，`image-age` 清理才能做出准确判断。在那之前，没有使用记录的镜像会被跳过。

## 本地缓存模型

本地缓存清理脚本把数据分成三类：

- `SAFE_TMP`：临时 `*.tmp` 目录，删除风险最低。
- `WORKSPACE_REBUILDABLE`：`runner-*` 下的陈旧项目工作区；删除后可能触发缓存重新解压或重新 clone/build，但不会删除归档缓存。
- `ARCHIVE_CACHE`：`cache.zip` 文件。当 `ENABLE_ARCHIVE_CLEANUP=1` 时，mtime 超过 `ARCHIVE_MAX_AGE_DAYS` 的归档文件会被删除。

## 文件说明

- `run.sh`：统一入口。
- `clean.sh`：旧的按仓库删除旧镜像辅助脚本；`run.sh` 不再调用它。
- `clear-docker-cache.sh`：Runner 管理的 Docker 容器/卷清理。
- `clear-runner-local-cache.sh`：主机侧 Runner 本地缓存扫描与清理。
- `track-docker-image-usage.py`：Docker 镜像使用追踪器，记录哪些镜像被 CI job 使用过。
- `systemd/docker-image-tracker.service`：镜像使用追踪器的 systemd 单元文件。
- `logrotate/runner-cleanup`：`/var/log/runner-cleanup/runner-cleanup.log` 的示例 logrotate 策略。
- `test/run-logging-smoke.sh`：内建文件日志的冒烟测试。
- `test/run-logging-behavior.sh`：日志路径、配置加载与退出日志行为验证。
- `test/run-dry-run-behavior.sh`：`run.sh` 对三层清理统一传递 `DRY_RUN` 的验证。
- `test/docker-dry-run-behavior.sh`：Docker 镜像/容器清理在 `DRY_RUN=1` 下不真实删除的验证。
- `test/clear-runner-local-cache-behavior.sh`：本地缓存活跃窗口和扫描行为验证。
- `runner-cleanup.conf.example`：配置文件示例。

## 使用方式

在 Runner 主机上克隆仓库并本地执行脚本：

```bash
git clone https://github.com/nh4ttruong/runner-cleanup.git
cd runner-cleanup
cp runner-cleanup.conf.example runner-cleanup.conf
bash run.sh
```

## 配置文件

推荐把长期配置写在 `runner-cleanup.conf` 中。

加载顺序：

- 如果设置了 `RUNNER_CLEANUP_CONFIG=/path/to/file`，优先使用它。
- 否则使用仓库目录下的 `runner-cleanup.conf`。
- 再否则使用当前工作目录下的 `./runner-cleanup.conf`。

环境变量仍然可用，并且会在临时执行时覆盖配置文件中的值。

## 配置项说明

下面这些是运维人员通常需要关心的配置项。它们来自 `runner-cleanup.conf.example`、显式环境变量覆盖，以及 `run.sh` / `clear-runner-local-cache.sh` 内的默认值。

### 用户可配置项

| 变量 | 默认值 | 使用位置 | 何时调整 |
| --- | --- | --- | --- |
| `KEEP_MAX_IMAGES` | `run.sh` 中为 `5` | 仅供手工调用 `clean.sh` 时使用 | 旧的按仓库保留镜像设置；`run.sh` 不再使用它。 |
| `ENABLE_IMAGE_CLEANUP` | `run.sh` 中为 `1` | `run.sh` -> `clear-docker-cache.sh image-prune` 和 `image-age` | 如果不希望删除 dangling 或过期 tagged Docker 镜像，设为 `0`。 |
| `IMAGE_MAX_AGE_DAYS` | `run.sh` 中为 `31` | `run.sh` -> `clear-docker-cache.sh image-age` | tagged 镜像的过期阈值（仅在 `ENABLE_IMAGE_CLEANUP=1` 时生效）。设为 `0` 可关闭。需要镜像使用追踪器运行。 |
| `ENABLE_DOCKER_CACHE_CLEANUP` | `run.sh` 中为 `1` | `run.sh` -> `clear-docker-cache.sh` | 如果不希望清理 Runner 管理的 Docker 对象，设为 `0`。 |
| `ENABLE_LOCAL_CACHE_CLEANUP` | `run.sh` 中为 `1` | `run.sh` -> `clear-runner-local-cache.sh` | 只有在这台主机完全不需要本地缓存清理时才建议关闭。 |
| `RUNNER_CACHE_DIR` | `/cache` | `clear-runner-local-cache.sh` | 仅在 Runner 本地缓存不在默认允许路径中时调整。 |
| `DRY_RUN` | `run.sh` 与子脚本中为 `1` | `run.sh`、`clean.sh`、`clear-docker-cache.sh`、`clear-runner-local-cache.sh` | 只有在确认整套清理流程都正确后才改成 `0`。 |
| `VERBOSE` | `clear-runner-local-cache.sh` 中为 `1` | `clear-runner-local-cache.sh` | 如果想减少日志输出，可设为 `0`。 |
| `ENABLE_TMP_CLEANUP` | `1` | `clear-runner-local-cache.sh` | 如果不想动 `*.tmp` 目录，设为 `0`。 |
| `ENABLE_WORKSPACE_CLEANUP` | `1` | `clear-runner-local-cache.sh` | 如果不想删陈旧工作区，设为 `0`。 |
| `ENABLE_ARCHIVE_CLEANUP` | `1` | `clear-runner-local-cache.sh` | 删除超过 `ARCHIVE_MAX_AGE_DAYS` 的 `cache.zip` 文件。设为 `0` 可关闭。 |
| `TMP_MAX_AGE_DAYS` | `1` | `clear-runner-local-cache.sh` | 想让 tmp 目录保留更久时调大。 |
| `WORKSPACE_MAX_AGE_DAYS` | `7` | `clear-runner-local-cache.sh` | 工作区的主要陈旧阈值。 |
| `ARCHIVE_MAX_AGE_DAYS` | `30` | `clear-runner-local-cache.sh` | `cache.zip` 归档保留天数；仅在 `ENABLE_ARCHIVE_CLEANUP=1` 时生效。 |
| `TOP_N_LARGEST` | `10` | `clear-runner-local-cache.sh` | 调整扫描输出中展示的最大路径数量。 |
| `RUNNER_CLEANUP_CONFIG` | 未设置 | `load-config.sh`, `run.sh` | 用来指定明确的配置文件路径，而不是自动发现。 |
| `RUNNER_CLEANUP_LOG_DIR` | `/var/log/runner-cleanup` | `run.sh` | 当默认日志目录不可写（例如本地非 root 测试）时覆盖。 |
| `RUNNER_CLEANUP_LOG_FILE` | `/var/log/runner-cleanup/runner-cleanup.log` | `run.sh` | 当需要写入不同日志文件时覆盖。 |

### 内部脚本变量

下面这些是实现细节，不是常规运维配置：

| 变量 | 产生位置 | 含义 |
| --- | --- | --- |
| `RUNNER_CLEANUP_LOADED_CONFIG` | `load-config.sh` | 实际加载到的配置文件绝对路径；`run.sh` 会把它写成日志里的 `config=...`。 |
| `RUNNER_CLEANUP_LOGGING_INITIALIZED` | `run.sh` | 内部标志，防止重复初始化启动日志。 |

除非你正在调试脚本本身，否则不要把这些内部变量写进 `runner-cleanup.conf`。

内建文件日志默认写到：

- `RUNNER_CLEANUP_LOG_DIR=/var/log/runner-cleanup`
- `RUNNER_CLEANUP_LOG_FILE=/var/log/runner-cleanup/runner-cleanup.log`

可以安装 `logrotate/runner-cleanup` 里的示例策略，避免日志无限增长。

如果是在本地非 root 环境运行，且 `/var/log/runner-cleanup` 不可写，请先导出 `RUNNER_CLEANUP_LOG_DIR` 和 `RUNNER_CLEANUP_LOG_FILE`，再执行 `run.sh`。

示例：

```bash
cp runner-cleanup.conf.example runner-cleanup.conf
vim runner-cleanup.conf
bash run.sh
```

## 默认行为

`run.sh` 只执行仓库内的本地脚本，不再从远程动态拉脚本执行。

默认值：

```bash
KEEP_MAX_IMAGES=5
ENABLE_IMAGE_CLEANUP=1
ENABLE_DOCKER_CACHE_CLEANUP=1
ENABLE_LOCAL_CACHE_CLEANUP=1
```

`run.sh` 按如下顺序执行清理：

1. `clear-docker-cache.sh image-prune`
2. `clear-docker-cache.sh image-age`（仅当 `IMAGE_MAX_AGE_DAYS > 0` 时）
3. `clear-docker-cache.sh`
4. `clear-runner-local-cache.sh`

三层清理都可以独立启用或关闭。

## Docker 清理配置

`run.sh` 和 `clear-docker-cache.sh` 使用这些 Docker 相关配置：

```bash
KEEP_MAX_IMAGES=5
ENABLE_IMAGE_CLEANUP=1
ENABLE_DOCKER_CACHE_CLEANUP=1
IMAGE_MAX_AGE_DAYS=31
```

- `KEEP_MAX_IMAGES`：旧配置，仅供手工调用 `clean.sh` 时使用。`run.sh` 不再使用它。
- `ENABLE_IMAGE_CLEANUP`：为 `1` 时执行 `clear-docker-cache.sh image-prune` 和 `image-age`（前提是 `IMAGE_MAX_AGE_DAYS > 0`）；为 `0` 时同时跳过这两步。
- `ENABLE_DOCKER_CACHE_CLEANUP`：为 `1` 时执行 `clear-docker-cache.sh`；为 `0` 时跳过。
- `IMAGE_MAX_AGE_DAYS`：大于 `0` 且 `ENABLE_IMAGE_CLEANUP=1` 时，在 image-prune 之后执行 `clear-docker-cache.sh image-age` 清理过期 tagged 镜像。需要镜像使用追踪器运行。

`ENABLE_IMAGE_CLEANUP` 这一层刻意保持保守：它只删除 dangling image，语义等价于 `docker image prune -f`，以及超过 `IMAGE_MAX_AGE_DAYS` 天未被 CI job 使用的 tagged 镜像。这一层不会执行 `docker image prune -a`、`docker system prune` 或 `docker system prune -a`，也不会删除正在使用中或有近期 CI 使用记录的 tagged image。

`ENABLE_DOCKER_CACHE_CLEANUP` 是独立的另一层，会保留 `clear-docker-cache.sh` 中原有的 Runner 管理 Docker 垃圾清理行为。启用时，这一层仍会执行带 GitLab Runner managed label 过滤条件的 Docker system prune 命令。

### `clean.sh`

- 这是旧的辅助脚本，`run.sh` 不会调用它。
- 通过 `docker images --format '{{.Repository}}'` 枚举 Docker 仓库。
- 是按"每个仓库"处理，而不是全局统一保留。
- 会删除较老的镜像 ID，并为每个仓库名保留最新的 `KEEP_MAX_IMAGES` 个唯一镜像 ID。
- 使用 `docker rmi -f`，因此这一层比本地缓存清理更激进。

### `clear-docker-cache.sh`

支持的命令：

```bash
bash clear-docker-cache.sh prune-volumes
bash clear-docker-cache.sh image-prune
bash clear-docker-cache.sh image-age
bash clear-docker-cache.sh prune
bash clear-docker-cache.sh space
bash clear-docker-cache.sh help
```

- `image-prune`：只删除 dangling Docker image，使用 `docker image prune -f`；不会删除 tagged image。
- `image-age`：删除超过 `IMAGE_MAX_AGE_DAYS` 天未被 CI job 使用过的 tagged Docker 镜像。读取追踪器产生的 `/var/lib/runner-cleanup/image-usage.json`。不会删除正在被任何容器使用的镜像、没有使用记录的镜像、或 dangling 镜像（由 image-prune 处理）。
- `prune-volumes`：删除未使用的 Runner 管理容器和卷。
- `prune`：仅删除未使用的 Runner 管理容器。
- `space`：显示 Docker 磁盘占用。
- `help`：显示帮助。

`run.sh` 调用 `clear-docker-cache.sh` 时不带参数，因此默认行为是 `prune-volumes`。

该脚本只会处理带有 GitLab Runner 管理标签的 Docker 对象：

```text
com.gitlab.gitlab-runner.managed=true
```

这样可以把清理范围限制在 Runner 创建的 Docker 资源上，而不会误伤普通用户容器。

手工执行现在默认就是观察模式：`run.sh` 默认启用三层清理，并把 `DRY_RUN=1` 一起传给镜像清理、Docker 清理和本地缓存清理。因此最安全的首次检查就是直接执行：

```bash
bash run.sh
```

如果要手工执行真实的 `runner-*` 清理，同时保留 48 小时活跃窗口：

```bash
DRY_RUN=0 bash run.sh
```

## 本地缓存清理配置

`clear-runner-local-cache.sh` 支持以下环境变量：

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

## 安全模型

- 只接受白名单缓存根目录：`/cache`、`/home/gitlab-runner/cache`、`/var/lib/gitlab-runner/cache`。
- 第一版只清理 `runner-*` 工作区和 `*.tmp` 目录。
- `cache.zip` archive 文件默认只扫描和计数；当 `ENABLE_ARCHIVE_CLEANUP=1` 时，mtime 超过 `ARCHIVE_MAX_AGE_DAYS` 的归档会被删除。
- `protected` 与非 `protected` 工作区分开处理。
- 如果某个目录树内最新的文件或目录 mtime 仍在活跃窗口内，则该工作区被视为活跃。

## Cron 示例

对于 cron，命令应尽量保持简单，把 dry-run / 真实清理的区别交给 `runner-cleanup.conf` 决定：

```cron
0 3 * * * cd /path/to/runner-cleanup && bash run.sh
```

推荐模型：

- 手工执行使用脚本默认值，因此 `bash run.sh` 默认会让三层清理都处于 dry-run 观察模式。
- cron 也执行同样的 `bash run.sh`，但该主机部署的 `runner-cleanup.conf` 决定实际运行模式。
- 在生产 runner 主机上，只有在人工检查过手工 dry-run 输出之后，才把部署配置里的 `DRY_RUN` 改成 `0`。

## 说明

- 运行脚本的用户需要有权限读取并删除目标缓存目录。
- 正常情况下，文件日志由 `run.sh` 处理，cron 不需要额外做 shell 重定向。
- 仓库中提供了 `logrotate` 示例配置：`logrotate/runner-cleanup`。
- 请通过系统标准的 logrotate 配置路径安装示例策略，避免清理日志无限增长。
- `DRY_RUN=1` 现在会保护三层清理；`clean.sh` 和 `clear-docker-cache.sh` 会打印"本来会执行的 Docker 命令"，而不会真正删除。
- `run.sh` 现在会在启动日志里打印 `DRY_RUN` 和三层开关状态，便于直接从 cron 日志判断这次到底是观察模式还是实删模式。
- 删除工作区数据后，后续 Job 可能因为重新恢复缓存或重新构建而变慢。
- 删除 archive 缓存（`cache.zip`）默认开启（`ENABLE_ARCHIVE_CLEANUP=1`）。只删除 mtime 超过 `ARCHIVE_MAX_AGE_DAYS`（默认 30 天）的归档。删除归档会导致对应 cache key 的真正 CI 缓存未命中。
- 日志里的 `config=` 表示实际加载到的配置文件路径；如果没有加载配置文件，则显示 `none`。

## 相关链接

- [GitLab Runner Docker executor docs](https://docs.gitlab.com/runner/executors/docker.html#clear-the-docker-cache)
- [GitLab CI caching docs](https://docs.gitlab.com/ci/caching/)
