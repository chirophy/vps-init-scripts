# VPS 一键初始化脚本

适用于 Debian 11+ / Ubuntu 22.04+，请以 **root** 用户在 VPS 的交互式终端中运行。DE 版推荐 Debian 13。

运行前请确认已安装 `curl`，并备份重要数据和现有配置。脚本会更新系统、调整网络参数并配置相关服务。

## 推荐：单文件整合入口

使用 `vps-init.sh`，只需将这一个文件放到 VPS 上即可运行，不依赖同目录中的旧版脚本。先选择场景与组件，再执行公共步骤；不用分别维护、运行多个版本。原有五个脚本暂时保留，供迁移核对和兼容旧入口。

整合版 [GitHub 仓库](https://github.com/chirophy/vps-init-scripts) / [Gist](https://gist.github.com/chirophy/f778ae67ce369aa623e193c1562842db)。远程下载后先预览方案：

```bash
curl -fsSL https://gist.githubusercontent.com/chirophy/f778ae67ce369aa623e193c1562842db/raw/vps-init.sh -o vps-init.sh && bash vps-init.sh --plan
```

下载成功并核对方案后，在目标 VPS 上以 root 执行：

```bash
# 只选择并预览方案，不安装或修改系统，普通用户也能运行
bash vps-init.sh --plan

# 在目标 VPS 上以 root 正式执行
bash vps-init.sh
```

场景选择：

| 序号 | 场景 | 自动执行的场景步骤 |
| --- | --- | --- |
| 1 | HK / JP 低延迟精品线路 | 低延迟 TCP 参数、fail2ban、iperf3 |
| 2 | LA 等高延迟跨洲线路 | 高延迟 TCP 参数、fail2ban、iperf3 |
| 3 | DE / 法兰克福 | DE 专用 TCP 参数、fail2ban、iperf3 |
| 4 | 精简基础版 | 低延迟 TCP 参数、fail2ban、iperf3，无 sing-box / NextTrace |
| 5 | 国内自托管服务 | Docker / Compose、NPM、Watchtower，以及选中的服务组 |
| 0 | 退出 | 不修改系统 |

所有场景共用主机名配置（可跳过）、APT 索引更新与系统升级、基础工具、Starship、自动安全更新和 journald 100M 日志限制。这些公共步骤每次运行只执行一次；场景所需软件包按需安装。

选择场景 1–3 后，再输入境外组件序号：`0` 均不安装、`1` NextTrace（默认）、`2` sing-box、`3` 两者都安装。只有选择 sing-box 时才处理其安装和自动更新任务；第三方安装器可能仍有自身交互。

选择场景 5 后，可按以下序号选择服务组，多个序号用逗号分隔，例如 `1,4,6`：

| 序号 | 服务组 | 服务 |
| --- | --- | --- |
| 1 | tools | Homepage、IT-Tools |
| 2 | code | Gitea |
| 3 | media | Navidrome、MeTube |
| 4 | rss | RSSHub、Browserless、Redis |
| 5 | files | File Browser、OpenList |
| 6 | monitoring | Uptime Kuma、Beszel |
| 7 | notes | Memos |
| 8 | all | 全部可选服务 |
| 0 | none | 仅 NPM + Watchtower（默认） |

整合版与旧版的差异：

- 国内服务从默认全部启动改为默认仅基础组件，按需选择其余服务。只有选中 `tools` 时才要求输入 Homepage 域名。
- Docker 镜像站由部署者通过 `DOCKER_MIRRORS` 提供可信地址，整合版不内置第三方镜像站；未设置时保留已有镜像站，新安装则使用原始镜像源。
- 四个境外场景统一按参数逐项探测可用性，未暴露或不可写的 TCP 参数会提示并跳过。HK / 精简版保留 16 MiB 缓冲上限，LA / DE 保留 32 MiB；DE 保留原有的发送缓冲默认值及专用参数。32 MiB 是自动调节上限，并非预分配内存。
- 已有系统配置在覆盖前备份；Docker daemon 仍先合并、校验，重启失败回滚。Compose 使用候选文件先校验，再备份并替换原文件；它不会自动合并手工修改的 Compose，请核对备份。
- NextTrace / sing-box 安装器先完整下载并通过 Bash 语法检查，再执行；语法检查不代表远程代码可信。未固定第三方安装器及容器镜像版本，内容可能随上游更新变化。
- 不选择某个组件只影响本次安装，不会卸载已有组件、停止已有容器或删除旧定时任务。切换服务选择并不等于移除上一次部署的服务。
- 检查 Debian 11+ / Ubuntu 22.04+ 及运行中的 systemd；受限容器兼容仅指 TCP 参数跳过，服务部署仍需要 systemd。无终端时必须显式提供场景。

### 环境变量与无人值守选择

交互输入均从 `/dev/tty` 读取。也可在执行前提供以下环境变量；正式运行前会检查场景、组件、端口、主机名等输入。`--plan` 只预览选择，不检查目标服务器环境、下载结果或容器可运行性。

| 环境变量 | 用途与默认值 |
| --- | --- |
| `VPS_SCENE` | `1`–`5`，也接受 `hk` / `la` / `de` / `minimal` / `domestic`；必须选择 |
| `VPS_COMPONENTS` | 场景 1–3 的工具序号 `0`–`3`，默认 `1`；精简/国内固定为 `0` |
| `SERVICE_PROFILES` | 国内服务序号或名称，例如 `1,4,6` 或 `tools,rss,monitoring`；默认 `0`，全部用 `8` / `all` |
| `VPS_HOSTNAME` | 新主机名；不提供时询问，回车或无终端则跳过 |
| `UPGRADE_SYSTEM` | 默认 `1`；`0` 跳过全系统升级，仍更新索引并安装工具 |
| `INSTALL_STARSHIP` | 默认 `1`；`0` 跳过 Starship |
| `RESET_STARSHIP_CONFIG` | 默认 `0` 保留已有主题；`1` 备份后重置 |
| `IPERF3_PORT` | 境外场景默认 `5201`，范围 1024–65535 |
| `HOMEPAGE_HOST` | 选中 `tools` 时必须提供或交互输入有效 DNS 域名 |
| `STACK_DIR` | 国内部署目录，默认 `/opt/stacks`，必须是非根目录的绝对路径 |
| `DOCKER_MIRRORS` | Docker 镜像站 JSON 数组，例如 `'["https://mirror.example.com"]'`；默认 `[]`，不改已有镜像站 |

```bash
# DE：安装 NextTrace，不安装 sing-box；先只预览
VPS_SCENE=3 VPS_COMPONENTS=1 bash vps-init.sh --plan

# 国内：仅部署 RSS 和监控组，不需要 Homepage 域名；先只预览
VPS_SCENE=5 SERVICE_PROFILES=4,6 bash vps-init.sh --plan

# 正式执行时去掉 --plan；请在目标 VPS 上以 root 运行
```

2026-10-21 已核对上述整合版 Gist，其 `vps-init.sh` 与本次同步的脚本内容一致。`raw` 最新地址未固定到具体修订，后续会随 Gist 更新变化。下方旧 Gist 地址仍对应原有独立入口，不应作为整合版下载地址。

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
```

新增隔离测试覆盖整合入口的五种场景调度、菜单序号映射、公共步骤只执行一次、只读预览、TCP 参数差异及受限内核跳过、Compose 令牌复用和校验失败保留原配置，以及第三方安装器下载失败/语法错误拦截。Docker / systemd / sysctl 等操作使用替身，不能替代真实 Debian / Ubuntu 隔离环境中的部署验收。

## 国内 VPS 数据与凭据

`domestic-vps-init.sh` 为旧版国内服务入口，当前未提供对应的远程运行地址；整合版选择场景 `5` 使用同一套服务定义。

Browserless 认证令牌在部署时随机生成，保存在服务器的 `/opt/stacks/.browserless.env`（权限 0600），重跑脚本时复用，RSSHub 与 Browserless 共享同一令牌。整合版可通过 `STACK_DIR` 改变目录。请勿上传此文件。手动管理容器时，在服务目录中使用 `docker compose --env-file .browserless.env <子命令>`；启动可选服务时还需带对应的 `--profile` 参数。

运行日志可能包含首次生成的管理员密码，请勿上传。
