# Runner Cleanup

用于清理 GitLab Runner 主机的 Shell 脚本集合，不修改 GitLab 或 Runner 服务端配置。

## 功能概览

- 删除旧 Docker 镜像，并为每个仓库保留最新的 `KEEP_MAX_IMAGES` 个镜像。
- 执行 GitLab Runner 管理的 Docker 容器与卷清理。
- 扫描并清理主机上 `runner-*` 目录下的本地 Runner 缓存。

## 清理层次

`run.sh` 可以驱动三层彼此独立的清理逻辑：

- `ENABLE_IMAGE_CLEANUP=1`：执行 `clean.sh` 清理旧 Docker 镜像。
- `ENABLE_DOCKER_CACHE_CLEANUP=1`：执行 `clear-docker-cache.sh` 清理 Runner 管理的 Docker 垃圾。
- `ENABLE_LOCAL_CACHE_CLEANUP=1`：执行 `clear-runner-local-cache.sh` 清理主机上的 `runner-*` 缓存/工作区数据。

Docker 侧清理与主机本地缓存清理不是一回事：

- Docker 清理针对 GitLab Runner 管理的 Docker 对象，例如已停止容器和未使用卷。
- 本地缓存清理针对主机缓存目录里的文件，尤其是 `runner-*` 工作区和 `*.tmp` 目录。

## 本地缓存模型

本地缓存清理脚本把数据分成三类：

- `SAFE_TMP`：临时 `*.tmp` 目录，删除风险最低。
- `WORKSPACE_REBUILDABLE`：`runner-*` 下的陈旧项目工作区；删除后可能触发缓存重新解压或重新 clone/build，但不会删除归档缓存。
- `ARCHIVE_CACHE`：`cache.zip` 文件。当前版本只扫描和计数，默认不会删除。

## 文件说明

- `run.sh`：统一入口。
- `clean.sh`：旧 Docker 镜像清理。
- `clear-docker-cache.sh`：Runner 管理的 Docker 容器/卷清理。
- `clear-runner-local-cache.sh`：主机侧 Runner 本地缓存扫描与清理。
- `logrotate/runner-cleanup`：`/var/log/runner-cleanup/runner-cleanup.log` 的示例 logrotate 策略。
- `test/run-logging-smoke.sh`：内建文件日志的冒烟测试。
- `runner-cleanup.conf.example`：配置文件示例。

## 使用方式

在 Runner 主机上克隆仓库并本地执行脚本：

```bash
git clone https://github.com/yaoge123/runner-cleanup.git
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
| `KEEP_MAX_IMAGES` | `run.sh` 中为 `5` | `clean.sh` | 调整每个 Docker 仓库保留的镜像数量。 |
| `ENABLE_IMAGE_CLEANUP` | `run.sh` 中为 `1` | `run.sh` -> `clean.sh` | 如果不希望删除旧 Docker 镜像，设为 `0`。 |
| `ENABLE_DOCKER_CACHE_CLEANUP` | `run.sh` 中为 `1` | `run.sh` -> `clear-docker-cache.sh` | 如果不希望清理 Runner 管理的 Docker 对象，设为 `0`。 |
| `ENABLE_LOCAL_CACHE_CLEANUP` | `run.sh` 中为 `1` | `run.sh` -> `clear-runner-local-cache.sh` | 只有在这台主机完全不需要本地缓存清理时才建议关闭。 |
| `RUNNER_CACHE_DIR` | `/cache` | `clear-runner-local-cache.sh` | 仅在 Runner 本地缓存不在默认允许路径中时调整。 |
| `DRY_RUN` | `clear-runner-local-cache.sh` 中为 `1` | `clear-runner-local-cache.sh` | 确认候选项正确前不要改成 `0`。 |
| `VERBOSE` | `clear-runner-local-cache.sh` 中为 `1` | `clear-runner-local-cache.sh` | 如果想减少日志输出，可设为 `0`。 |
| `ENABLE_TMP_CLEANUP` | `1` | `clear-runner-local-cache.sh` | 如果不想动 `*.tmp` 目录，设为 `0`。 |
| `ENABLE_WORKSPACE_CLEANUP` | `1` | `clear-runner-local-cache.sh` | 如果不想删陈旧工作区，设为 `0`。 |
| `ENABLE_DUPLICATE_WORKSPACE_REPORT` | `1` | `clear-runner-local-cache.sh` | 如果不需要重复工作区报告，设为 `0`。 |
| `ENABLE_DUPLICATE_WORKSPACE_CLEANUP` | `1` | `clear-runner-local-cache.sh` | 如果即使重复也不想自动删除陈旧副本，设为 `0`。 |
| `ENABLE_ARCHIVE_CLEANUP` | `0` | `clear-runner-local-cache.sh` | 预留给未来；当前代码只扫描和计数 archive 文件。 |
| `TMP_MAX_AGE_DAYS` | `1` | `clear-runner-local-cache.sh` | 想让 tmp 目录保留更久时调大。 |
| `WORKSPACE_MAX_AGE_DAYS` | `7` | `clear-runner-local-cache.sh` | 工作区和重复副本的主要陈旧阈值。 |
| `ACTIVE_WINDOW_HOURS` | `48` | `clear-runner-local-cache.sh` | 如果最近活跃目录需要保护更久，可调大。 |
| `KEEP_WORKSPACE_COPIES` | `1` | `clear-runner-local-cache.sh` | 想为同一 `namespace/project + protection` 保留更多副本时调大。 |
| `MAX_DELETE_GB_PER_RUN` | `10` | `clear-runner-local-cache.sh` | 想更保守就调低，想更快回收空间就调高。 |
| `TOP_N_LARGEST` | `20` | `clear-runner-local-cache.sh` | 调整扫描输出中展示的最大路径数量。 |
| `RUNNER_CLEANUP_CONFIG` | 未设置 | `load-config.sh`, `run.sh` | 用来指定明确的配置文件路径，而不是自动发现。 |
| `RUNNER_CLEANUP_LOG_DIR` | `/var/log/runner-cleanup` | `run.sh` | 当默认日志目录不可写（例如本地非 root 测试）时覆盖。 |
| `RUNNER_CLEANUP_LOG_FILE` | `/var/log/runner-cleanup/runner-cleanup.log` | `run.sh` | 当需要写入不同日志文件时覆盖。 |

### 内部脚本变量

下面这些是实现细节，不是常规运维配置：

| 变量 | 产生位置 | 含义 |
| --- | --- | --- |
| `RUNNER_CLEANUP_LOADED_CONFIG` | `load-config.sh` | 实际加载到的配置文件绝对路径；`run.sh` 会把它写成日志里的 `config=...`。 |
| `RUNNER_CLEANUP_LOGGING_INITIALIZED` | `run.sh` | 内部标志，防止重复初始化启动日志。 |
| `BOOTSTRAP_LOG_DIR` | `run.sh` | 最终配置完成前使用的临时启动日志目录。 |
| `BOOTSTRAP_LOG_FILE` | `run.sh` | 最终配置完成前使用的临时启动日志文件。 |
| `FINAL_LOG_DIR` | `run.sh` | 配置/环境变量求值后的最终日志目录。 |
| `FINAL_LOG_FILE` | `run.sh` | 配置/环境变量求值后的最终日志文件。 |

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

1. `clean.sh "${KEEP_MAX_IMAGES}"`
2. `clear-docker-cache.sh`
3. `clear-runner-local-cache.sh`

三层清理都可以独立启用或关闭。

## Docker 清理配置

`run.sh`、`clean.sh` 和 `clear-docker-cache.sh` 使用这些 Docker 相关配置：

```bash
KEEP_MAX_IMAGES=5
ENABLE_IMAGE_CLEANUP=1
ENABLE_DOCKER_CACHE_CLEANUP=1
```

- `KEEP_MAX_IMAGES`：作为位置参数传给 `clean.sh`；对每个 Docker 仓库名，只保留最新的 `KEEP_MAX_IMAGES` 个镜像，删除更老的。
- `ENABLE_IMAGE_CLEANUP`：为 `1` 时执行 `clean.sh`；为 `0` 时完全跳过旧镜像清理。
- `ENABLE_DOCKER_CACHE_CLEANUP`：为 `1` 时执行 `clear-docker-cache.sh`；为 `0` 时跳过 Runner 管理的 Docker 容器/卷清理。

### `clean.sh`

- 通过 `docker images --format '{{.Repository}}'` 枚举 Docker 仓库。
- 是按“每个仓库”处理，而不是全局统一保留。
- 会删除较老的镜像 ID，并为每个仓库名保留最新的 `KEEP_MAX_IMAGES` 个镜像。
- 使用 `docker rmi -f`，因此这一层比本地缓存清理更激进。

### `clear-docker-cache.sh`

支持的命令：

```bash
bash clear-docker-cache.sh prune-volumes
bash clear-docker-cache.sh prune
bash clear-docker-cache.sh space
bash clear-docker-cache.sh help
```

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

手工执行现在默认就是观察模式：`run.sh` 默认启用本地缓存清理，而 `clear-runner-local-cache.sh` 仍然默认 `DRY_RUN=1`。因此最安全的首次检查就是直接执行：

```bash
bash run.sh
```

如果要手工执行真实的 `runner-*` 清理，同时保留 48 小时活跃窗口：

```bash
DRY_RUN=0 bash run.sh
```

如果只想临时一次性覆盖而不改配置文件：

```bash
DRY_RUN=0 MAX_DELETE_GB_PER_RUN=20 bash run.sh
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

## 安全模型

- 只接受白名单缓存根目录：`/cache`、`/home/gitlab-runner/cache`、`/var/lib/gitlab-runner/cache`。
- 第一版只清理 `runner-*` 工作区和 `*.tmp` 目录。
- `cache.zip` archive 文件只扫描和计数，默认不删除。
- `protected` 与非 `protected` 工作区分开处理。
- 如果某个目录树内最新的文件或目录 mtime 仍在活跃窗口内，则该工作区被视为活跃。
- 重复工作区清理会按 `namespace/project + protection` 保留最新的 `KEEP_WORKSPACE_COPIES` 份副本，同时仍遵守 `WORKSPACE_MAX_AGE_DAYS`。
- 每次运行的删除总量受 `MAX_DELETE_GB_PER_RUN` 限制。

## Cron 示例

对于 cron，命令应尽量保持简单，把 dry-run / 真实清理的区别交给 `runner-cleanup.conf` 决定：

```cron
0 3 * * * cd /path/to/runner-cleanup && bash run.sh
```

推荐模型：

- 手工执行使用脚本默认值，因此 `bash run.sh` 默认就是 dry-run 观察。
- cron 也执行同样的 `bash run.sh`，但该主机部署的 `runner-cleanup.conf` 决定实际运行模式。
- 在生产 runner 主机上，只有在人工检查过手工 dry-run 输出之后，才把部署配置里的 `DRY_RUN` 改成 `0`。

## 说明

- 运行脚本的用户需要有权限读取并删除目标缓存目录。
- 正常情况下，文件日志由 `run.sh` 处理，cron 不需要额外做 shell 重定向。
- 仓库中提供了 `logrotate` 示例配置：`logrotate/runner-cleanup`。
- 删除工作区数据后，后续 Job 可能因为重新恢复缓存或重新构建而变慢。
- 删除 archive 缓存仍然故意保持关闭状态。
- 日志里的 `config=` 表示实际加载到的配置文件路径；如果没有加载配置文件，则显示 `none`。

## 相关链接

- [GitLab Runner Docker executor docs](https://docs.gitlab.com/runner/executors/docker.html#clear-the-docker-cache)
- [GitLab CI caching docs](https://docs.gitlab.com/ci/caching/)
