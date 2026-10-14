# VPS 一键初始化脚本

适用于 Debian 11+ / Ubuntu 22.04+，请以 **root** 用户在 VPS 的交互式终端中运行。DE 版推荐 Debian 13。

运行前请确认已安装 `curl`，并备份重要数据和现有配置。脚本会更新系统、调整网络参数并配置相关服务。

## HK / JP

适合香港、日本等低延迟、低丢包精品线路（如 CN2 GIA / CMI / IIJ）。对应本地文件：`overseas-vps-init.sh`。

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/db29814b8bf3c1c48290cddf31765462/raw)
```

## 长距离大带宽专用 · LA

适合 LA 等美西、美东或欧洲的高延迟跨洲线路，通常为 RTT 130ms 以上。对应本地文件：`overseas-vps-init-la.sh`。

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/f3adef4a19c2cfba6da7013a5d920a8c/raw)
```

## DE 专用

面向德国法兰克福线路，针对 1C1G+、500 Mbps、三网 AS9929 优化线路及中国方向约 150–250ms RTT 的场景调优。受限容器中会跳过无法修改的 TCP 参数。对应本地文件：`overseas-vps-init-de.sh`。

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/0eccbcaefb81591de73b8efb635bcdf3/raw/)
```

## 无 sb / NextTrace

适合只需要基础系统初始化的低延迟精品线路，不安装 sing-box、NextTrace，也不配置 sing-box 自动更新。对应本地文件：`overseas-vps-init-minimal.sh`。

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/chirophy/5fbbad98f4dd048cd9177eedde6ca605/raw)
```

## 运行说明

- 主机名在运行时输入，直接回车可跳过。
- HK / JP、LA、DE 版会询问是否安装 sing-box，默认跳过；NextTrace 会自动安装。
- 四个境外版本均配置 TCP 调优、fail2ban、自动安全更新、日志限制，以及 iperf3 后台服务。
- iperf3 默认监听 TCP / UDP `5201`，没有身份认证，应通过防火墙或安全组仅允许可信 IP 访问。可在运行命令前设置 `export IPERF3_PORT=其他端口`（范围 1024–65535）。
- 版本选择应结合实际延迟、丢包和带宽；TCP 调优无法改变运营商路由或突破服务商带宽限制。
- 下载执行命令需要 Bash。`curl -fsSL` 会跟随重定向，并报告 HTTP 错误；若下载报错，请先解决错误再运行。

上述 Gist 地址由用户提供，版本用途按本地脚本说明整理，尚未核实远端内容与本地文件是否一致。`raw` 地址没有固定到具体修订，执行内容会随 Gist 更新而变化。

## 国内 VPS

`domestic-vps-init.sh` 用于 Docker / Compose 自托管服务部署，当前未提供对应的远程运行地址。

Browserless 认证令牌在部署时随机生成，保存在服务器的 `/opt/stacks/.browserless.env`（权限 0600），重跑脚本时复用。请勿上传此文件。手动管理容器时，在 `/opt/stacks` 目录中使用 `docker compose --env-file .browserless.env <子命令>`；启动可选服务时还需带对应的 `--profile` 参数。

运行日志可能包含首次生成的管理员密码，请勿上传。
