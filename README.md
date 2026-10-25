# VPS 一键初始化脚本

适用于 Debian 11+ / Ubuntu 22.04+，请以 **root** 用户在 VPS 的交互式终端中运行。DE 版推荐 Debian 13。

运行前请确认已安装 `curl`，并备份重要数据和现有配置。完整初始化会更新系统、调整网络参数并配置相关服务；其他模式的范围见下表。

## 推荐：单文件整合入口

使用 `vps-init.sh`，只需将这一个文件放到 VPS 上即可运行，不依赖同目录中的旧版脚本。启动后先显示本机系统概况，再选择操作、用途 / 线路、工具或服务组，最后设置后台任务并查看本次执行方案。原有五个脚本暂时保留，供迁移核对和兼容旧入口。

系统概况包括主机名、发行版、内核与架构、CPU、内存和 Swap、根分区容量、运行时长、系统负载、虚拟化、systemd 状态及当前用户。只读取本机文件或运行只读命令，不联网探测、不安装依赖；缺少字段或探测命令时显示“未知”，继续进入菜单。`--plan` 同样显示概况；`--help` 直接显示帮助。正式执行前仍会严格检查支持的系统版本、root 权限和 systemd。

整合版 [GitHub 仓库](https://github.com/chirophy/vps-init-scripts) / [Gist](https://gist.github.com/chirophy/f778ae67ce369aa623e193c1562842db)。从 GitHub 下载当前版本并预览方案；Gist 作为另行同步的备用入口：

```bash
curl -fsSL https://raw.githubusercontent.com/chirophy/vps-init-scripts/main/vps-init.sh -o vps-init.sh && bash vps-init.sh --plan
```

下载成功并核对方案后，在目标 VPS 上以 root 执行：

```bash
# 只选择并预览方案，不安装或修改系统，普通用户也能运行
bash vps-init.sh --plan

# 在目标 VPS 上以 root 正式执行
bash vps-init.sh
```

操作菜单增加适用情况说明，原编号和默认值保持不变：新机器选 `1` 完整初始化；补装工具、部署应用或调整后台任务选 `2` 安装 / 调整组件；查看运行状态选 `3`；更新已有工具或服务选 `4`。操作菜单新增 `0` 直接退出。

随后选择服务器用途 / 线路。下表中的 TCP 与系统配置仅在“完整初始化”时执行；其他操作用该选择确定组件范围：

| 序号 | 用途 / 线路 | 完整初始化的场景步骤 |
| --- | --- | --- |
| 1 | HK / JP 低延迟精品线路 | 低延迟 TCP 参数、fail2ban；工具及常驻服务另选 |
| 2 | LA 等高延迟跨洲线路 | 高延迟 TCP 参数、fail2ban；工具及常驻服务另选 |
| 3 | DE / 法兰克福 | DE 专用 TCP 参数、fail2ban；工具及常驻服务另选 |
| 4 | 精简基础版 | 低延迟 TCP 参数、fail2ban，无 sing-box / NextTrace；iperf3 另选 |
| 5 | Docker 自托管服务（原国内场景） | Docker / Compose、NPM，以及选中的服务组；Watchtower 另选 |
| 0 | 退出 | 不修改系统 |

场景 `5` 可用于国内外 VPS，`VPS_SCENE=domestic` 的自动化名称保留兼容；镜像代理是否需要配置取决于服务器网络。

各操作的具体范围：

| 模式序号 | `VPS_MODE` | 操作范围 |
| --- | --- | --- |
| 1 | `full`（默认，直接回车选择） | 完整初始化：主机名、APT 更新/升级、基础工具、Starship、安全更新、日志限制，以及场景步骤 |
| 2 | `components` | 安装 / 调整组件：仅安装所选组件及其依赖，或调整后台任务；更新 APT 索引，但强制跳过系统升级，不改主机名、Starship、安全策略或 TCP 参数 |
| 3 | `status` | 只读检查现有服务；不安装依赖、不创建令牌文件或改权限；国内场景按所选服务验收 |
| 4 | `update` | 国内复用已有 Compose、拉取并启动所选服务；境外对已安装的所选 NextTrace 重新运行原安装器，对 sb 执行脚本/内核更新；不重新初始化系统或设置定时任务 |

完整初始化的公共步骤每次只执行一次；配置内容一致时不重复备份、写入或重启服务。补装工具建议选模式 `2`，查看状态选 `3`，主动升级服务选 `4`。普通安装模式不再主动拉取已有服务的新镜像，缺失镜像仍由 Compose 按其策略拉取。

最终方案用中文显示实际操作、服务与后台任务；组件 / 状态 / 更新模式不会把 TCP 调优列为待执行步骤，更新模式明确显示“更新工具”。

所有编号菜单均按选项逐行显示。选择场景 1–3 后，再选择境外组件；直接回车默认选择 `1`。NextTrace 用于查看网络路由与链路，sing-box 提供代理服务及管理工具。更新模式只更新已安装的所选工具，状态模式不显示工具安装菜单：

| 组件序号 | 安装内容 |
| --- | --- |
| 1 | NextTrace + sing-box（默认） |
| 2 | 仅 NextTrace |
| 3 | 仅 sing-box |
| 0 | 不选择 |

安装 sing-box 与启用其定时更新分别选择；第三方安装器可能仍有自身交互。sing-box 根据实际内核版本检查和 `sing-box.service` 运行状态判断安装结果，兼容上游安装成功但返回非零退出码的情况。优先检查 `/etc/sing-box/bin/sing-box`，避免把 PATH 中的管理脚本当作内核；仅有管理入口、内核不可用或服务未运行都会返回失败。已经安装且服务运行时会跳过安装，已有残留但未通过检查时会提示排查，不自动重装或重新生成节点。精简版和国内场景仍不选择这些境外组件，状态检查也不会安装组件。

完整初始化和组件模式还会分别询问后台任务：

| 变量 | 对应任务 | 选项 |
| --- | --- | --- |
| `IPERF3_ACTION` | 境外 iperf3 常驻服务 | `1` 安装并启用（默认）、`2` 不启用，停止已有服务并取消开机启动 |
| `WATCHTOWER_ACTION` | 国内 Watchtower 自动更新 | `1` 纳入启动服务（默认）、`2` 不启用，停止已有 Watchtower 容器 |
| `SB_UPDATE_ACTION` | sing-box 每日定时更新 | `1` 配置并启用（适用时默认）、`2` 不启用，移除该更新任务，保留其他 cron 条目 |

新装时后台任务菜单只有以下两项，直接回车选择 `1`：

```text
1) 启用（默认）
2) 不启用
```

后台菜单会说明任务用途并显示当前状态。检测到已有服务、容器或更新任务时，选项 `2` 明确显示为“停用已有任务”，并增加 `0) 保持现状`。已有任务同样默认选择 `1`；明确选择 `2` 才停用，选择 `0` 则不作调整。`ACTION=0` 仍接受显式环境变量，兼容此前的自动化，但新装菜单不再展示没有实际意义的“保持现状”。sing-box 定时更新采用服务器时区的每日 04:00。

sing-box 定时更新只有在已有 `/usr/local/bin/sb`，或本次选择新装 sing-box 时才默认询问并启用；只选 NextTrace、不选组件或精简版且没有已有 `sb` 时会跳过。已有健康原生内核但没有 `sb` 管理入口时也跳过；显式要求启用不适用的定时更新会在系统修改前报错。检查/更新模式不显示这些菜单，所有 ACTION 默认保持为 `0`，启停操作使用组件模式。

iperf3 默认端口 `5201` 且无身份认证，默认启用常驻服务后应仅向可信 IP 放行。

选择场景 5 后，先选择服务组，再设置 Watchtower。多个序号用逗号分隔，例如 `1,4,6`；`0` 和 `8` 必须单独使用。菜单用中文用途分组，并说明 NPM 是始终包含的反向代理与证书管理服务。状态模式对缺少或未运行的容器报告异常；更新模式复用已有 Compose 定义，所选服务尚无容器时，会按已有配置创建并启动：

| 序号 | 服务组 | 服务 |
| --- | --- | --- |
| 1 | tools（导航与工具） | Homepage、IT-Tools |
| 2 | code（代码托管） | Gitea |
| 3 | media（音乐与下载） | Navidrome、MeTube |
| 4 | rss（RSS 订阅） | RSSHub、Browserless、Redis |
| 5 | files（文件管理） | File Browser、OpenList |
| 6 | monitoring（服务监控） | Uptime Kuma、Beszel |
| 7 | notes（笔记备忘） | Memos |
| 8 | all | 全部可选服务 |
| 0 | none | NPM 基础服务（默认，Watchtower 独立选择且默认启用） |

整合版与旧版的差异：

- 国内服务从默认全部启动改为默认仅基础组件，按需选择其余服务。只有选中 `tools` 时才要求输入 Homepage 域名。
- 重跑及追加其他服务组时复用已有 Homepage 域名；通过 `HOMEPAGE_HOST` 可显式修改。FileBrowser 挂载宿主机 `/root`，以 UID/GID `0:0` 运行以便直接管理其中的文件；只预建缺失的应用配置 / 数据库目录，不更改 `/root` 或已有目录的权限与所有权。
- Watchtower 固定为 `1.7.1`，启用前检查 Docker 服务端 API 范围并验证所选 API，避免默认 `1.25` 与 Docker 29 不兼容。它只更新带本脚本 `vps-init` scope 和 enable 标签的容器，不更新其他项目；Memos 排除在自动更新范围外。旧容器在组件模式重新生成配置并重建后才获得这些标签。
- Docker 镜像站由部署者通过 `DOCKER_MIRRORS` 提供可信地址，整合版不内置第三方镜像站；未设置时保留已有镜像站，新安装则使用原始镜像源。
- 四个境外场景统一按参数逐项探测可用性，未暴露或不可写的 TCP 参数会提示并跳过。HK / 精简版保留 16 MiB 缓冲上限，LA / DE 保留 32 MiB；DE 保留原有的发送缓冲默认值及专用参数。32 MiB 是自动调节上限，并非预分配内存。
- fail2ban、Docker daemon、安全更新 drop-in 和 journald 使用配置事务：只备份发生变化的文件；校验失败恢复原文件，启动失败还尝试恢复服务原有运行状态。自动安全更新不再覆盖现有 `20auto-upgrades` 和 `50unattended-upgrades`；只有缺少传统周期配置时才维护独立 `20vps-auto-upgrades`，更新来源、清理和自动重启策略沿用现有配置。
- Compose 使用候选文件先校验，内容有变化才备份替换；启动验收失败时恢复原 Compose 并尝试恢复原服务配置。首次部署失败会撤回新 Compose，保留容器供排查。恢复不包含服务数据或镜像版本回退；不会自动合并手工修改的 Compose，请核对备份。
- 国内服务根据当前选择逐一验收，默认最多等待 300 秒；缺少容器、退出、重启中、不健康或状态读取失败均返回失败。有健康检查的容器必须为 `healthy`，没有健康检查时仅确认进程为 `running`，会明确标注，不表示应用接口已可用。多副本需全部满足条件，低配置或数据库迁移较慢时可调整 `SERVICE_WAIT_TIMEOUT`。
- NextTrace / sing-box 安装器先完整下载并通过 Bash 语法检查，再执行；连接超时 15 秒、下载最长 120 秒，安装器输入使用控制终端或空输入，不读取脚本管道。语法检查不代表远程代码可信。第三方安装器和多数容器镜像仍随上游变化，Memos / Watchtower 使用固定版本。
- 手动和定时 sing-box 更新共享互斥锁，每条更新命令最长 900 秒，超时后给予 30 秒退出时间；更新后连续检查内核和服务。仅锁被占用时跳过，权限或锁工具错误返回失败。定时更新在取得锁后轮转日志；部署脚本、启动 cron、写入任务任一步失败都停止并报告失败。
- 修改 cron 前读取失败会停止，原任务备份到 `/var/backups/vps-init/`（目录 0700、备份 0600）；只匹配实际执行本更新脚本的任务，不删除把该路径作为参数的其他任务。多文件配置先完成全部备份再写入，启动或 enable 失败会恢复配置和服务状态。
- APT 更新使用 `APT::Update::Error-Mode=any`，临时下载错误也会中止。已有 Docker 会独立检查和补装 Compose 插件，缺少可用软件源时在修改 daemon 配置前报错。`registry-mirrors` 仅适用于 Docker Hub；GHCR 需配置 daemon 网络代理或显式使用可信仓库地址。
- iperf3 在写配置前检查端口归属，启动后确认监听属于本服务进程。新建自动安全更新策略时启用 APT timers；已有策略保留，并报告调度器是否运行。journald 同时设置持久日志和内存日志上限为 100M。
- 不选择某个组件不会卸载或删除它；切换服务组也不等于移除上次部署的服务。适用的后台任务默认启用，选择 `2` 执行对应停用操作；已有任务选择 `0` 保留现状。
- 检查 Debian 11+ / Ubuntu 22.04+ 及运行中的 systemd；受限容器兼容仅指 TCP 参数跳过，服务部署仍需要 systemd。无终端时必须显式提供场景。

### 环境变量与无人值守选择

交互输入均从 `/dev/tty` 读取。也可在执行前提供以下环境变量；正式运行前会检查场景、组件、端口、主机名等输入。`--plan` 显示本机概况并预览选择，不做部署环境的强制校验，不验证下载结果或容器可运行性。

| 环境变量 | 用途与默认值 |
| --- | --- |
| `VPS_MODE` | `1`–`4` 或 `full` / `components` / `status` / `update`，默认 `full`；`0` 退出 |
| `VPS_SCENE` | `1`–`5`，也接受 `hk` / `la` / `de` / `minimal` / `domestic`；必须选择 |
| `VPS_COMPONENTS` | 按上方组件表选择，默认 `1`（NextTrace + sing-box）；精简/国内固定为 `0`。此前设置过该变量时，请按新映射调整 |
| `SERVICE_PROFILES` | 国内服务序号或名称，例如 `1,4,6` 或 `tools,rss,monitoring`；默认 `0`，全部用 `8` / `all` |
| `VPS_HOSTNAME` | 新主机名；不提供时询问，回车或无终端则跳过 |
| `UPGRADE_SYSTEM` | 默认 `1`；`0` 跳过全系统升级，仍更新索引并安装工具 |
| `INSTALL_STARSHIP` | 默认 `1`；`0` 跳过 Starship |
| `RESET_STARSHIP_CONFIG` | 默认 `0` 保留已有主题；`1` 备份后重置 |
| `IPERF3_PORT` | 境外场景默认 `5201`，范围 1024–65535 |
| `IPERF3_ACTION` / `WATCHTOWER_ACTION` / `SB_UPDATE_ACTION` | 安装模式中适用的任务默认 `1` 启用，`2` 不启用/停用已有任务；显式 `0` 保持。检查/更新模式默认 `0`，不适用的任务也为 `0` |
| `SERVICE_WAIT_TIMEOUT` | 国内服务启动验收等待秒数，默认 `300`，范围 1–3600；状态检查立即报告结果 |
| `HOMEPAGE_HOST` | 首次选中 `tools` 时提供或输入域名；重跑默认复用已有值，显式设置可覆盖 |
| `MEMOS_IMAGE` | 默认 `neosmemo/memos:0.31.0`；重跑保留已有镜像选择，也可设为 `ghcr.io/usememos/memos:0.31.0` |
| `STACK_DIR` | 国内部署目录，默认 `/opt/stacks`，必须是非根目录的绝对路径 |
| `DOCKER_MIRRORS` | Docker 镜像站 JSON 数组，例如 `'["https://mirror.example.com"]'`；默认 `[]`，不改已有镜像站 |

```bash
# DE：安装 NextTrace，不安装 sing-box；先只预览
VPS_SCENE=3 VPS_COMPONENTS=2 bash vps-init.sh --plan

# 国内：仅部署 RSS 和监控组，不需要 Homepage 域名；先只预览
VPS_SCENE=5 SERVICE_PROFILES=4,6 bash vps-init.sh --plan

# 仅补装 NextTrace，同时启用 iperf3，不配置 sing-box 更新，不执行全系统升级；先预览
VPS_MODE=components VPS_SCENE=1 VPS_COMPONENTS=2 IPERF3_ACTION=1 bash vps-init.sh --plan

# 查看现有 RSS 服务组的状态（目标 VPS 上运行）
VPS_MODE=status VPS_SCENE=5 SERVICE_PROFILES=4 bash vps-init.sh

# 复用已有配置，更新 RSS 服务组；先预览
VPS_MODE=update VPS_SCENE=5 SERVICE_PROFILES=4 bash vps-init.sh --plan

# 正式执行时去掉 --plan；请在目标 VPS 上以 root 运行
```

GitHub 与整合版 Gist 分别同步。核对版本时，可对两个来源下载的脚本分别运行 `sha256sum`，相同版本应得到相同摘要。下方旧 Gist 地址仍对应原有独立入口，不应作为整合版下载地址。

### Memos 镜像与已有数据升级

2026-10-24 实际查询官方 Registry：以下四个引用均可读取，且当前 manifest 摘要相同，支持 linux/amd64、linux/arm64、linux/arm/v7；`neosmemo/memos:latest` 返回 404。

| 仓库 | 固定版本（默认推荐） | 跟随稳定版 |
| --- | --- | --- |
| Docker Hub | `neosmemo/memos:0.31.0` | `neosmemo/memos:stable` |
| GHCR | `ghcr.io/usememos/memos:0.31.0` | `ghcr.io/usememos/memos:stable` |

amd64 和 arm64 的 `0.31.0` 配置及全部镜像层已实际下载并逐项校验 SHA256。这是 Registry 下载验证；没有在本机执行 Docker 容器启动。固定版本便于计划数据库迁移，脚本默认排除 Memos 的 Watchtower 自动更新。

已有旧版数据库升级前，先备份数据库和附件，核对当前版本及[官方升级路径](https://usememos.com/docs/operations/upgrade)：早于 0.22 的版本需先成功运行 `0.25.3`，再升级 `0.31.0`；未来升级至 26.10 时必须先经过 `0.31.0`。数据库迁移后不能仅靠换回旧镜像回滚，需要数据备份。

如果检测到旧模板 `latest` 和已有数据，安装/组件模式选择 notes 时会要求显式设置 `MEMOS_IMAGE`，避免猜测迁移路径。只追加其他服务组不会修改这类旧 Memos 的镜像选择；状态模式也不会触发迁移。升级模式复用现有 Compose；应用本次模板修复请使用组件模式重新生成配置，例如新装 Memos：

```bash
VPS_MODE=components VPS_SCENE=domestic SERVICE_PROFILES=notes \
  MEMOS_IMAGE=neosmemo/memos:0.31.0 bash vps-init.sh
```

## 旧版独立入口

### HK / JP

适合香港、日本等低延迟、低丢包精品线路（如 CN2 GIA / CMI / IIJ）。对应本地文件：`overseas-vps-init.sh`。

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/db29814b8bf3c1c48290cddf31765462/raw)
```

### 长距离大带宽专用 · LA

适合 LA 等美西、美东或欧洲的高延迟跨洲线路，通常为 RTT 130ms 以上。对应本地文件：`overseas-vps-init-la.sh`。

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/f3adef4a19c2cfba6da7013a5d920a8c/raw)
```

### DE 专用

面向德国法兰克福线路，针对 1C1G+、500 Mbps、三网 AS9929 优化线路及中国方向约 150–250ms RTT 的场景调优。受限容器中会跳过无法修改的 TCP 参数。对应本地文件：`overseas-vps-init-de.sh`。

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/0eccbcaefb81591de73b8efb635bcdf3/raw/)
```

### 无 sb / NextTrace

适合只需要基础系统初始化的低延迟精品线路，不安装 sing-box、NextTrace，也不配置 sing-box 自动更新。对应本地文件：`overseas-vps-init-minimal.sh`。

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/5fbbad98f4dd048cd9177eedde6ca605/raw)
```

## 旧版运行说明

- 主机名在运行时输入，直接回车可跳过。
- 软件包索引更新与系统升级分别检查错误，任一步失败都会停止初始化。默认执行系统升级；可设置 `export UPGRADE_SYSTEM=0` 跳过全系统升级，但仍更新软件包索引并安装脚本所需工具。此开关不影响自动安全更新配置。
- HK / JP、LA、DE 版会询问是否安装 sing-box，默认跳过；NextTrace 会自动安装。
- 四个境外版本均配置 TCP 调优、fail2ban、自动安全更新、日志限制，以及 iperf3 后台服务。
- 五个版本默认安装 Starship，并为当前 root 账号配置 Bash 彩色单行提示符；可设置 `export INSTALL_STARSHIP=0` 跳过安装和配置。
- iperf3 默认监听 TCP / UDP `5201`，没有身份认证，应通过防火墙或安全组仅允许可信 IP 访问。可在运行命令前设置 `export IPERF3_PORT=其他端口`（范围 1024–65535）。
- 版本选择应结合实际延迟、丢包和带宽；TCP 调优无法改变运营商路由或突破服务商带宽限制。
- 下载执行命令需要 Bash。`curl -fsSL` 会跟随重定向，并报告 HTTP 错误；若下载报错，请先解决错误再运行。

本节四个旧版 Gist 地址由用户提供，版本用途按本地脚本说明整理，尚未核实这些旧版远端内容与本地文件是否一致。`raw` 地址没有固定到具体修订，执行内容会随 Gist 更新而变化。

## Starship 终端美化（整合入口与全部旧版）

系统基础工具安装后，脚本会从 [Starship 官方站点](https://starship.rs/) 完整下载安装程序，再执行非交互安装；已安装时复用现有版本，不强制升级。下载或安装失败会提示并跳过美化，继续其他初始化。

- 使用 Bash + Starship，不安装 fish、不更换账号登录 Shell，也不自动卸载已有 fish。如果当前仍在 fish 中，请先完成切回 Bash 的操作；Bash 的初始化命令不能在 fish 中执行。
- 当前 root 账号的 `~/.config/starship.toml` 不存在时，自动创建内置简洁配置；已存在时默认保留，不重置用户修改。内置配置中 root 用户名红色、普通用户名绿色、主机名青色、目录黄色；进入 Git 仓库时显示分支，命令超过 2 秒显示耗时，`>` 根据上一条命令成功或失败显示绿色或红色。
- `format = '$username$hostname$directory$git_branch$cmd_duration$character'` 不包含 `$line_break`，让 `>` 和目录显示在同一行；`add_newline = false` 去掉提示符之间的额外空行。窄终端或过长内容仍可能自然折行。使用普通字符，无需 Nerd Font。
- 在 `~/.bashrc` 和当前生效的 Bash 登录文件（依次选择已有的 `~/.bash_profile`、`~/.bash_login`、`~/.profile`，均不存在时创建 `~/.profile`）末尾维护初始化区块，仅交互式 Bash 加载，同一个 Shell 只初始化一次。区块通过 `STARSHIP_CONFIG` 固定使用上述配置文件。
- 重跑时默认保留已有 Starship 主题；显式设置 `export RESET_STARSHIP_CONFIG=1` 才重新应用内置单行配置。Shell 文件仍只替换本脚本管理的区块，其他内容保留。文件有变化时先生成同目录的 `.bak.<时间戳>.<随机后缀>` 备份；内容相同则不重写。Shell 文件先通过 `bash -n` 校验，再写入。
- 不会在初始化脚本中启动交互 Shell。完成后重新连接 SSH，或在当前 **Bash** 中运行 `source ~/.bashrc`。已有的 `exec fish` 等自动切换配置仍需自行清理。
- Starship 负责命令前面的提示符，不提供 fish 的灰色自动建议，也不改变 `ls` 输出配色。

后续自行调整样式：

```bash
nano ~/.config/starship.toml
```

已有 Starship 配置默认保留，无需设置额外变量。需要在下一次运行脚本时重置为内置单行主题，可先设置：

```bash
export RESET_STARSHIP_CONFIG=1
```

重置后可用 `unset RESET_STARSHIP_CONFIG` 恢复默认的保留行为。如果要完全跳过 Starship 的安装与配置，设置：

```bash
export INSTALL_STARSHIP=0
```

本地运行示例（按实际版本更换文件名）：

```bash
bash overseas-vps-init.sh
```

相关逻辑的隔离测试（只在临时目录生成文件，APT 与 Starship 安装命令使用替身，不执行初始化脚本）：

```bash
bash tests/starship-config-test.sh
bash tests/system-update-test.sh
bash tests/unified-init-test.sh
bash tests/reliability-test.sh
bash tests/singbox-install-test.sh
bash tests/audit-regression-test.sh
```

`unified-init-test.sh` 另覆盖系统概况只读探测、缺失信息回退、菜单前显示概况、操作菜单直接退出，以及先选服务组再选 Watchtower 的顺序与各模式方案范围。

`audit-regression-test.sh` 覆盖本轮审计的失败路径、配置保留和镜像模板，若本机有独立 Compose CLI，可设置 `COMPOSE_TEST_BIN=/path/to/docker-compose`，用真实 CLI 校验全部 15 个服务，无需 daemon。临时 Bash/工具兼容环境中的测试不能替代 Linux 上真实 systemd / Docker 验收。

本次主要维护整合入口；旧版独立脚本同步了 APT 严格错误处理与境外主机名长度、hosts 地址匹配修正，其他增强逻辑请使用整合入口。

新增隔离测试覆盖五种场景和四种模式、菜单映射、真实空行输入默认值、新装/已有后台任务菜单、只读状态探测、定时更新适用条件、公共步骤只执行一次、只读预览、TCP 差异、Compose 令牌复用与失败恢复、后台任务独立启停、健康状态解析、无变化跳过及原有自动更新策略保留。sing-box 专项测试覆盖成功但非零退出、退出零但内核缺失/服务未运行、已有实例跳过和节点文件保留。Docker / systemd / sysctl 等操作使用替身，不能替代真实 Debian / Ubuntu 隔离环境中的部署验收。

## 国内 VPS 数据与凭据

`domestic-vps-init.sh` 为旧版国内服务入口，当前未提供对应的远程运行地址；整合版选择场景 `5` 使用同一套服务定义。

整合版与旧版国内入口使用以下固定宿主机目录，路径区分大小写，且不随 `STACK_DIR` 改变：

| 用途 | VPS 宿主机目录 | 容器内目录 | 访问方式 |
| --- | --- | --- | --- |
| FileBrowser 管理的文件 | `/root` | `/srv` | 读写，容器以 root 运行 |
| Navidrome 音乐库 | `/Music` | `/music` | 只读 |
| OpenList 应用数据 | `/OpenList` | `/opt/openlist/data` | 读写 |

FileBrowser 的配置和数据库仍保存在 `${STACK_DIR}/Filebrowser/config`、`${STACK_DIR}/Filebrowser/database`；Navidrome 应用数据库仍在 `${STACK_DIR}/navidrome/data`。其他服务的数据路径不变。`/OpenList` 是 OpenList 自身配置与数据库目录，后台添加的本地存储需要另行挂载对应文件目录。

已有部署切换目录前，先备份数据并停止对应容器，再将原 `${STACK_DIR}/music` 中的音乐放入 `/Music`、原 `${STACK_DIR}/openlist/data` 的内容迁入 `/OpenList`，保留文件权限；目标目录已有内容时先核对，避免覆盖。脚本不会自动搬迁或删除旧目录。此前 `${STACK_DIR}/Filebrowser/files` 中的文件也会保留，需要继续通过 FileBrowser 管理的文件可自行移入 `/root` 下。

应用新挂载需要使用操作 `2`（安装 / 调整组件）、场景 `5`，选择服务组 `3,5` 重新生成配置并重建相应容器；操作 `4` 沿用原 Compose，不会更改旧挂载。已配置的后台任务可以选择 `0` 保持现状。

Browserless 认证令牌在部署时随机生成，保存在服务器的 `/opt/stacks/.browserless.env`（权限 0600），重跑脚本时复用，RSSHub 与 Browserless 共享同一令牌。整合版可通过 `STACK_DIR` 改变目录。请勿上传此文件。手动管理容器时，在服务目录中使用 `docker compose --env-file .browserless.env <子命令>`；启动可选服务时还需带对应的 `--profile` 参数。

运行日志可能包含首次生成的管理员密码，请勿上传。
