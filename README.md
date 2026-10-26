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

选择场景 `5` 后按需多选服务组，例如 `1,4,6`。NPM 始终包含，Watchtower 自动更新单独选择。

| 序号 | 服务 |
| --- | --- |
| 1 | Homepage、IT-Tools |
| 2 | Gitea |
| 3 | Navidrome、MeTube |
| 4 | RSSHub、Browserless、Redis |
| 5 | File Browser、OpenList |
| 6 | Uptime Kuma、Beszel |
| 7 | Memos |
| 8 | 全部可选服务 |
| 0 | 仅 NPM（默认） |

- Compose 默认位于 `/root/docker-compose.yml`，应用绑定目录统一放在 `/root` 下，可通过 `STACK_DIR` 调整。
- File Browser 固定管理 `/root`；音乐库默认 `/root/Music`，OpenList 应用数据默认 `/root/OpenList`；Redis 保留命名卷。
- Browserless 共享令牌保存在 `/root/.browserless.env`（权限 `0600`）。手动运行 Compose 时须通过 `--env-file` 加载该文件，请勿上传。
- 所选服务全部达到 `running + healthy` 才通过验收，默认最多等待 300 秒，可通过 `SERVICE_WAIT_TIMEOUT` 调整。

应用新的挂载或健康检查配置，请选择操作 `2`；操作 `4` 沿用已有 Compose。旧部署迁移前请停服并备份，手动迁移 Compose、令牌和应用数据；脚本不会自动搬迁文件。旧自定义项目在容器已删除后迁移时，通过 `COMPOSE_PROJECT_NAME` 指定原项目名。

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
