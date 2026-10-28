# VPS 一键初始化脚本

适用于 Debian 11+ / Ubuntu 22.04+，需要 Bash、curl 和运行中的 systemd。请在目标 VPS 上以 root 执行，运行前备份重要数据。

## 整合版（推荐）

单文件 `vps-init.sh`，按菜单选择操作、线路、组件和后台任务。

[GitHub 仓库](https://github.com/chirophy/vps-init-scripts) · [Gist 备用入口](https://gist.github.com/chirophy/f778ae67ce369aa623e193c1562842db)

下载并预览方案（不修改系统）：

```bash
curl -fsSL https://raw.githubusercontent.com/chirophy/vps-init-scripts/main/vps-init.sh -o vps-init.sh && bash vps-init.sh --plan
```

确认方案后执行：

```bash
bash vps-init.sh
```

| 操作 | 用途 |
| --- | --- |
| 1 · 完整初始化 | 新机器：基础工具、系统配置和所选组件 |
| 2 · 安装 / 调整组件 | 补装工具、部署应用、调整后台任务；跳过系统升级 |
| 3 · 查看状态 | 只读检查现有服务 |
| 4 · 更新服务 | 更新所选组件，沿用已有配置 |

线路 / 场景：`1` HK / JP、`2` LA、`3` DE、`4` 精简基础版、`5` Docker 自托管服务（国内外均可选）。输入 `0` 退出。

更多参数和环境变量：

```bash
bash vps-init.sh --help
```

## Docker 服务

选择场景 `5` 后按需多选服务组，例如 `1,4,6,9`。NPM 与 PostgreSQL 始终包含，Watchtower 自动更新单独选择。

| 序号 | 服务 |
| --- | --- |
| 1 | Homepage、IT-Tools |
| 2 | Gitea |
| 3 | Navidrome、MeTube |
| 4 | RSSHub、Browserless、Redis |
| 5 | File Browser、OpenList |
| 6 | Uptime Kuma、Beszel、Komari |
| 7 | Memos |
| 8 | 全部可选服务 |
| 9 | pgAdmin（PostgreSQL 管理） |
| 10 | RustDesk（hbbs ID 服务、hbbr 中继服务） |
| 0 | 仅 NPM、PostgreSQL（默认） |

- Compose 默认位于 `/root/docker-compose.yml`，应用绑定目录统一放在 `/root` 下，可通过 `STACK_DIR` 调整；pgAdmin 与 Redis 使用 Docker 命名卷。
- File Browser 固定管理 `/root`；音乐库默认 `/root/Music`，OpenList 应用数据默认 `/root/OpenList`；Redis 保留命名卷。
- Browserless 共享令牌保存在 `/root/.browserless.env`（权限 `0600`）。手动运行 Compose 时须通过 `--env-file` 加载该文件，请勿上传。
- 新部署的 NPM、Gitea、Memos、OpenList 共用 `postgresql:5432`，各用独立数据库和非管理员账号；Komari 的指标库也使用独立的 PostgreSQL 数据库，其账号和站点配置仍由 Komari 保存在本地 SQLite 中。RSSHub 继续使用 Redis；其他服务保留各自支持的存储方式。
- PostgreSQL 固定为 `17-alpine`，不交给 Watchtower 自动升级；数据保存在 `postgresql/data`，初次启动自动建库，补装时只创建缺失的库和账号，不重置已有密码。5432 不发布到公网。
- 数据库密码、pgAdmin 和 Komari 初始账号密码在部署时随机生成，保存在 `.database.env`（权限 `0600`），重跑复用。首次可通过 `POSTGRES_PASSWORD`、`NPM_DB_PASSWORD`、`GITEA_DB_PASSWORD`、`MEMOS_DB_PASSWORD`、`OPENLIST_DB_PASSWORD`、`KOMARI_DB_PASSWORD`、`PGADMIN_DEFAULT_PASSWORD`、`KOMARI_ADMIN_PASSWORD` 自行提供，限 16–128 位字母、数字、下划线或连字符；Komari 密码还须含大小写字母和数字。已有文件优先于环境变量，删除文件不会重置数据库密码。
- pgAdmin 的邮箱通过 `PGADMIN_DEFAULT_EMAIL` 设置（首次默认 `admin@example.com`），登录密码见 `.database.env`，已预置 PostgreSQL 服务器地址；连接时使用文件中的 `POSTGRES_PASSWORD`。Komari 首次自动完成安装，用户名为 `admin`，密码见 `KOMARI_ADMIN_PASSWORD`。已有 Komari 实例保留原账号和指标库，不自动迁移。
- 应用连接分别保存在 `.database-connections/{npm,gitea,memos,openlist}.env`（目录 `0700`、文件 `0600`）。首次接入脚本时，优先保留原 Compose 中的数据库环境变量；应用目录已有文件时保留原数据库，避免把 SQLite 或自定义连接切到空库。后续复用这些连接文件；切换数据库须另行备份和迁移，不能只删除连接文件。
- pgAdmin、Komari 统一通过 NPM 访问，反代目标分别为 `pgadmin4:80`、`komari:25774`，沿用脚本原有的容器内网部署方式。
- 所选服务通常需达到 `running + healthy` 才通过验收，默认最多等待 300 秒，可通过 `SERVICE_WAIT_TIMEOUT` 调整。RustDesk classic 镜像基于 scratch，没有健康探针，两个容器仅检查 `running`；注册与中继连通性仍须通过客户端验证。

### RustDesk

整合版选择操作 `2` → 场景 `5` → 服务组 `10`（或 `SERVICE_PROFILES=rustdesk`）；`8/all` 也包含该组。旧版 `domestic-vps-init.sh` 使用 profile 名称 `rustdesk`，其 `all` 同样包含该组。

- 保留 [RustDesk 官方 Compose 示例](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/) 的镜像、命令、依赖、主机网络与重启策略；共享挂载改为 `./rustdesk/data:/root`，默认宿主机路径为 `/root/rustdesk/data`。已有 `./data` 部署请先停服并备份，将原数据和密钥迁入新目录，避免生成新密钥导致客户端不匹配。
- `network_mode: host` 适用于本项目的 Linux VPS，无需配置 `ports`，也不加入 Compose 默认桥接网络。请在服务器防火墙和云安全组放行 **TCP 21115–21117、UDP 21116**，脚本不会自动开放这些端口。
- 不用 Web 客户端时保持 TCP 21118/21119 关闭；需要 Web 客户端时，按官方说明通过反向代理提供访问，并限制这两个端口只能由代理连接。
- 客户端的 ID 服务器填写 VPS 公网 IP 或域名，中继服务器可显式填写同一地址的 `21117` 端口；Key 填写 `rustdesk/data/id_ed25519.pub` 的内容。不要分享或提交无 `.pub` 后缀的私钥 `id_ed25519`。`depends_on` 只控制启动顺序，不代表中继已可用。
- 保留用户指定的 `latest` 标签；整合版启用 Watchtower 时这两个服务也参与自动更新。正式使用前请分别验证 ID 注册、直连及强制中继连接。

### 手动管理

手动管理新部署时，同时加载两个凭据文件：

```bash
cd /root
docker compose --env-file .browserless.env --env-file .database.env --profile database ps
```

对照用户提供的 Compose，补入 PostgreSQL、pgAdmin、Komari；未复制其中的私人目录、1Panel 容器名、外部网络和凭据。Gitea 沿用脚本原有社区版镜像，不自动换为参考文件中的企业版。数据库连接依据 [NPM](https://nginxproxymanager.com/setup/)、[Gitea](https://docs.gitea.com/installation/install-with-docker)、[Memos](https://usememos.com/docs/configuration/database)、[OpenList](https://doc.oplist.org/configuration/configuration) 官方说明；Komari 使用其 [1.6.0 首次安装接口](https://github.com/komari-monitor/komari/blob/1.6.0/web/install/install.go) 配置指标库。

应用新的挂载、数据库连接或健康检查配置，请选择操作 `2`；操作 `4` 沿用已有 Compose。旧部署迁移前请停服并备份，手动迁移 Compose、令牌、`.database.env`、`.database-connections`、`postgresql/init` 和应用数据；脚本不会自动搬迁文件。旧自定义项目在容器已删除后迁移时，通过 `COMPOSE_PROJECT_NAME` 指定原项目名。

## 旧版执行方式

**HK / JP**

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/db29814b8bf3c1c48290cddf31765462/raw)
```

**LA**

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/f3adef4a19c2cfba6da7013a5d920a8c/raw)
```

**DE / 法兰克福**

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/0eccbcaefb81591de73b8efb635bcdf3/raw/)
```

**精简版（无 sing-box / NextTrace）**

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/5fbbad98f4dd048cd9177eedde6ca605/raw)
```

**国内 Docker 版（仓库中的本地文件）**

```bash
bash domestic-vps-init.sh
```

旧版 Gist 地址沿用原 README，未核对其远端内容与本地脚本是否一致。
