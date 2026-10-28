#!/bin/bash
# ============================================================
# 国内 VPS 一键初始化脚本
# 适用系统：Debian 11+ / Ubuntu 22.04+
# 内容：Docker + Compose 全套自托管服务部署
# ============================================================

set -euo pipefail

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}======== $1 ========${NC}"; }

# ---------- Starship 公共配置（各版本保持一致） ----------
# 使用子 Shell 清理临时文件，不改变主脚本或调用者的 Shell。
configure_starship() (
    case "${INSTALL_STARSHIP:-1}" in
        0) info "已通过 INSTALL_STARSHIP=0 跳过 Starship"; return 0 ;;
        1) ;;
        *) error "INSTALL_STARSHIP 仅支持 0 或 1"; return 1 ;;
    esac

    case "${RESET_STARSHIP_CONFIG:-0}" in
        0|1) ;;
        *) error "RESET_STARSHIP_CONFIG 仅支持 0 或 1"; return 1 ;;
    esac

    local account_home work_dir installer login_file file staged backup_id i
    local theme_preserved=false
    local -a targets staged_files
    account_home=$(getent passwd "$EUID" | cut -d: -f6)
    if [[ "$account_home" != /* || ! -d "$account_home" ]]; then
        error "无法确定当前 root 账号的主目录，停止配置 Starship"
        return 1
    fi
    work_dir=$(mktemp -d)
    trap 'rm -rf -- "$work_dir"' EXIT
    installer="$work_dir/install.sh"

    if command -v starship >/dev/null 2>&1; then
        info "Starship 已安装，将复用现有版本"
    else
        info "从 Starship 官方站点下载安装程序..."
        # 先完整下载再执行，下载失败时不执行残缺脚本。
        if ! curl -fsSL --connect-timeout 15 --max-time 120 \
            https://starship.rs/install.sh -o "$installer"; then
            warn "Starship 安装程序下载失败，跳过终端美化；其他初始化继续"
            return 0
        fi
        install -d -m 0755 /usr/local/bin
        if ! sh "$installer" --yes --bin-dir /usr/local/bin; then
            warn "Starship 安装失败，跳过终端美化；其他初始化继续"
            return 0
        fi
        hash -r
    fi
    if ! starship --version; then
        warn "Starship 无法运行，保留现有 Shell 配置；其他初始化继续"
        return 0
    fi

    cat > "$work_dir/starship.toml" << 'STARSHIP_CONFIG_EOF'
# VPS 简洁单行提示符：无需 Nerd Font。
add_newline = false
format = '$username$hostname$directory$git_branch$cmd_duration$character'

[username]
show_always = true
style_root = 'bold red'
style_user = 'bold green'
format = '[$user]($style)'

[hostname]
ssh_only = false
style = 'bold cyan'
format = '[@$hostname]($style) '

[directory]
style = 'bold yellow'
format = '[$path]($style)[$read_only]($read_only_style) '
read_only = ' (ro)'
truncation_length = 3
truncate_to_repo = false

[git_branch]
symbol = 'git:'
style = 'bold purple'
format = '[$symbol$branch]($style) '

[cmd_duration]
min_time = 2000
format = '[took $duration](bold yellow) '

[character]
success_symbol = '[>](bold green)'
error_symbol = '[>](bold red)'
STARSHIP_CONFIG_EOF

    # .bash_profile / .bash_login 存在时，Bash 登录不一定读取 .profile。
    # 同时配置 .bashrc 和实际生效的登录文件；同一个 Shell 只初始化一次。
    login_file="$account_home/.profile"
    for file in "$account_home/.bash_profile" "$account_home/.bash_login" "$account_home/.profile"; do
        if [[ -f "$file" ]]; then
            login_file="$file"
            break
        fi
    done
    targets=("$account_home/.config/starship.toml" "$account_home/.bashrc" "$login_file")
    staged_files=("$work_dir/starship.toml" "$work_dir/bashrc" "$work_dir/login")
    for i in 1 2; do
        file=${targets[$i]}
        staged=${staged_files[$i]}
        : > "$staged"
        if [[ -e "$file" ]]; then
            # 只替换本脚本管理的区块，保留用户的其他配置。
            if ! awk '
                $0 == "# >>> vps-init starship >>>" { if (inside) exit 1; inside=1; next }
                $0 == "# <<< vps-init starship <<<" { if (!inside) exit 1; inside=0; next }
                !inside { print }
                END { if (inside) exit 1 }
            ' "$file" > "$staged"; then
                error "$file 的 Starship 标记不完整，未修改原文件"
                return 1
            fi
        fi
        cat >> "$staged" << 'STARSHIP_INIT_EOF'
# >>> vps-init starship >>>
# 仅在交互式 Bash 中加载，避免其他 Shell 解析 Bash 初始化代码。
if [ -n "${BASH_VERSION:-}" ] && [ "${__VPS_STARSHIP_INITIALIZED:-}" != "$$" ]; then
    case $- in
        *i*)
            if command -v starship >/dev/null 2>&1; then
                export STARSHIP_CONFIG="$HOME/.config/starship.toml"
                eval "$(starship init bash)"
                __VPS_STARSHIP_INITIALIZED=$$
            fi
            ;;
    esac
fi
# <<< vps-init starship <<<
STARSHIP_INIT_EOF
        if ! bash -n "$staged"; then
            error "$file 的 Bash 语法校验失败，未修改原文件"
            return 1
        fi
    done

    mkdir -p "$account_home/.config"
    backup_id="$(date +%Y%m%d-%H%M%S).${work_dir##*.}"
    # 全部准备并校验后再写入；有内容变化时才备份和替换。
    for i in 0 1 2; do
        file=${targets[$i]}
        staged=${staged_files[$i]}
        # 默认保留已有主题；只有明确要求重置时才应用内置单行样式。
        if [[ "$i" == 0 && "${RESET_STARSHIP_CONFIG:-0}" == 0 ]] && \
            [[ -e "$file" || -L "$file" ]]; then
            theme_preserved=true
            info "已保留已有 Starship 配置: $file（RESET_STARSHIP_CONFIG=1 可重置）"
            continue
        fi
        if cmp -s "$staged" "$file"; then
            continue
        fi
        if [[ -e "$file" ]]; then
            cp -pL -- "$file" "$file.bak.$backup_id"
            info "已备份: $file.bak.$backup_id"
        fi
        cp -- "$staged" "$file"
    done
    if [[ "$theme_preserved" == true ]]; then
        info "Starship Bash 自动加载已配置，继续使用已有主题"
    else
        info "Starship 已配置：彩色单行提示符（> 与目录同一行），无额外空行"
    fi
    info "重新连接 SSH，或在当前 Bash 执行: source ~/.bashrc"
    info "仅配置当前 root 账号；不会切换登录 Shell 或卸载 fish"
)
# ---------- Starship 公共配置结束 ----------

# ---------- 配置区 ----------
STACK_DIR="/opt/stacks"

# Docker Hub 国内镜像（按需修改，失效可替换）
# 注意：第三方镜像站失效率高且存在被投毒风险，请仅从可信渠道更新此列表
DOCKER_MIRRORS='[
    "https://docker.m.daocloud.io",
    "https://dockerhub.icu",
    "https://docker.nastool.de"
]'

# ---------- 前置检查 ----------
if [[ $EUID -ne 0 ]]; then
    error "请以 root 用户运行此脚本"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    error "无法读取 /etc/os-release"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
    error "此脚本仅支持 Debian / Ubuntu 系统"
    exit 1
fi

if [[ -z "${VERSION_CODENAME:-}" ]]; then
    error "无法识别系统版本代号（VERSION_CODENAME）"
    exit 1
fi

# ---------- 1. 修改主机名 ----------
step "1/5 修改主机名"
# 从 /dev/tty 读取，避免 curl | bash 场景下 stdin 被脚本占用
read -rp "请输入新主机名（直接回车跳过）: " NEW_HOSTNAME < /dev/tty || NEW_HOSTNAME=""
if [[ -n "$NEW_HOSTNAME" ]]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    # 同步 /etc/hosts，避免 sudo 报 "unable to resolve host"
    if grep -qE '^127\.0\.1\.1([[:space:]]|$)' /etc/hosts; then
        sed -i -E "s/^127\.0\.1\.1([[:space:]]|$).*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
    else
        echo -e "127.0.1.1\t${NEW_HOSTNAME}" >> /etc/hosts
    fi
    info "主机名已设置为: $NEW_HOSTNAME（/etc/hosts 已同步）"
else
    warn "跳过主机名修改"
fi

# ---------- 2. 系统更新 & 基础工具 ----------
step "2/5 系统更新 & 基础工具"
# 非交互模式：避免 conffile 冲突弹窗和 needrestart 交互卡死脚本
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
# ---------- 更新软件包索引与系统升级 ----------
case "${UPGRADE_SYSTEM:-1}" in
    0|1) ;;
    *) error "UPGRADE_SYSTEM 仅支持 0 或 1"; exit 1 ;;
esac
if ! apt-get update -o APT::Update::Error-Mode=any; then
    error "软件包索引更新失败，停止初始化；请解决 APT 错误后重试"
    exit 1
fi
if [[ "${UPGRADE_SYSTEM:-1}" == 1 ]]; then
    if ! apt-get upgrade -y -o Dpkg::Options::="--force-confold"; then
        error "系统升级失败，停止初始化；请解决 APT 错误后重试"
        exit 1
    fi
else
    info "已通过 UPGRADE_SYSTEM=0 跳过系统升级，仍更新索引并安装所需工具"
fi
# ---------- 系统升级处理结束 ----------
apt-get install -y curl wget ca-certificates tar gnupg jq unattended-upgrades
info "系统更新及基础工具安装完成"

step "终端美化：Starship（Bash）"
configure_starship

# 启用自动安全更新
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF

systemctl enable --now unattended-upgrades
info "自动安全更新已启用（仅安全补丁，不自动重启）"

# 限制 journald 日志大小（drop-in 方式，不修改主配置文件）
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/limit.conf << 'EOF'
[Journal]
SystemMaxUse=100M
EOF
systemctl restart systemd-journald
info "journald 日志上限已设为 100M"

# ---------- 3. 安装 Docker & Compose ----------
step "3/5 安装 Docker & Compose"

if command -v docker &>/dev/null; then
    warn "Docker 已安装: $(docker --version)"
else
    info "使用 Docker 官方 APT 仓库安装 Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc || {
        error "Docker 官方仓库签名密钥下载失败，请检查网络后重试"
        exit 1
    }
    chmod a+r /etc/apt/keyrings/docker.asc

    DOCKER_ARCH=$(dpkg --print-architecture)
    cat > /etc/apt/sources.list.d/docker.sources << DOCKER_REPO_EOF
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${DOCKER_ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO_EOF

    apt-get update -o APT::Update::Error-Mode=any
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    info "Docker 安装完成: $(docker --version)"
fi

systemctl enable --now docker

# 配置 Docker daemon（国内镜像加速 + 日志限制）
mkdir -p /etc/docker
# 将本脚本的配置合并到现有 daemon.json；写入前校验，重启失败则回滚
DAEMON_FILE="/etc/docker/daemon.json"
DAEMON_BACKUP=""
DAEMON_FRAGMENT=$(mktemp /etc/docker/daemon.fragment.XXXXXX)
DAEMON_CANDIDATE=$(mktemp /etc/docker/daemon.candidate.XXXXXX)

cat > "${DAEMON_FRAGMENT}" << DAEMON_EOF
{
    "registry-mirrors": ${DOCKER_MIRRORS},
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    }
}
DAEMON_EOF

if [[ -f "${DAEMON_FILE}" ]]; then
    DAEMON_BACKUP="${DAEMON_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${DAEMON_FILE}" "${DAEMON_BACKUP}"
    info "已有 daemon.json 已备份为: ${DAEMON_BACKUP}"
    if ! jq -s '.[0] * .[1]' "${DAEMON_FILE}" "${DAEMON_FRAGMENT}" > "${DAEMON_CANDIDATE}"; then
        rm -f "${DAEMON_FRAGMENT}" "${DAEMON_CANDIDATE}"
        error "现有 daemon.json 无法解析，未修改原文件"
        exit 1
    fi
else
    cp "${DAEMON_FRAGMENT}" "${DAEMON_CANDIDATE}"
fi

if ! jq empty "${DAEMON_CANDIDATE}" 2>/dev/null || \
   ! dockerd --validate --config-file "${DAEMON_CANDIDATE}" &>/dev/null; then
    rm -f "${DAEMON_FRAGMENT}" "${DAEMON_CANDIDATE}"
    error "合并后的 daemon.json 未通过校验，原配置未修改"
    exit 1
fi

install -m 0644 "${DAEMON_CANDIDATE}" "${DAEMON_FILE}"
rm -f "${DAEMON_FRAGMENT}" "${DAEMON_CANDIDATE}"

if ! systemctl restart docker; then
    error "Docker 重启失败，正在回滚 daemon.json..."
    if [[ -n "${DAEMON_BACKUP}" ]]; then
        cp -a "${DAEMON_BACKUP}" "${DAEMON_FILE}"
    else
        rm -f "${DAEMON_FILE}"
    fi
    if systemctl restart docker; then
        error "已回滚到修改前的 Docker 配置"
    else
        error "回滚后 Docker 仍无法启动，请运行: journalctl -u docker -n 100"
    fi
    exit 1
fi
info "Docker daemon 已合并配置（国内镜像加速 + 全局日志限制）"

# 验证 compose 插件
if docker compose version &>/dev/null; then
    info "Docker Compose 就绪: $(docker compose version --short)"
else
    error "Docker Compose 插件未安装，请检查 Docker 版本"
    exit 1
fi

# ---------- 4. 生成 docker-compose.yml ----------
step "4/5 生成 docker-compose.yml"

# Homepage 仅接受单个 DNS 域名：禁止通配符、协议、端口和路径
is_valid_domain() {
    local domain="$1" label
    local -a labels=()

    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != .* && "$domain" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}

HOMEPAGE_HOST="${HOMEPAGE_HOST:-}"
while ! is_valid_domain "${HOMEPAGE_HOST}"; do
    if [[ -n "${HOMEPAGE_HOST}" ]]; then
        warn "域名格式无效：仅允许类似 nav.example.com 的 DNS 域名"
    fi
    if [[ ! -r /dev/tty ]]; then
        error "非交互运行时必须通过 HOMEPAGE_HOST 环境变量提供有效域名"
        exit 1
    fi
    read -rp "请输入 Homepage 允许访问的域名（如 nav.example.com，不允许 *）: " HOMEPAGE_HOST < /dev/tty || {
        error "无法读取 Homepage 域名"
        exit 1
    }
done
info "Homepage 允许访问域名: ${HOMEPAGE_HOST}"

# NPM 与 Watchtower 始终启动；其余服务按 profile 分类选择
AVAILABLE_PROFILES=(tools code media rss files monitoring notes rustdesk)
declare -A ENABLED_PROFILES=()
COMPOSE_PROFILE_ARGS=()
PROFILE_SELECTION="${SERVICE_PROFILES:-}"

echo "可选服务 profiles："
echo "  tools       Homepage、IT-Tools"
echo "  code        Gitea"
echo "  media       Navidrome、MeTube"
echo "  rss         RSSHub、Browserless、Redis"
echo "  files       File Browser、OpenList"
echo "  monitoring  Uptime Kuma、Beszel"
echo "  notes       Memos"
echo "  rustdesk    RustDesk（hbbs、hbbr）"

if [[ -z "${PROFILE_SELECTION}" ]]; then
    if [[ -r /dev/tty ]]; then
        read -rp "请选择 profiles（逗号分隔；all=全部，none=仅基础组件，默认 all）: " PROFILE_SELECTION < /dev/tty || PROFILE_SELECTION="all"
    else
        PROFILE_SELECTION="all"
    fi
fi
PROFILE_SELECTION="${PROFILE_SELECTION:-all}"

if [[ "${PROFILE_SELECTION}" == "all" ]]; then
    for profile in "${AVAILABLE_PROFILES[@]}"; do
        ENABLED_PROFILES["$profile"]=1
    done
elif [[ "${PROFILE_SELECTION}" != "none" ]]; then
    IFS=',' read -r -a REQUESTED_PROFILES <<< "${PROFILE_SELECTION}"
    for profile in "${REQUESTED_PROFILES[@]}"; do
        profile="${profile//[[:space:]]/}"
        case " ${AVAILABLE_PROFILES[*]} " in
            *" ${profile} "*) ENABLED_PROFILES["$profile"]=1 ;;
            *)
                error "未知 profile: ${profile}"
                exit 1
                ;;
        esac
    done
fi

SELECTED_PROFILE_NAMES=()
for profile in "${AVAILABLE_PROFILES[@]}"; do
    if [[ -n "${ENABLED_PROFILES[$profile]+x}" ]]; then
        COMPOSE_PROFILE_ARGS+=(--profile "$profile")
        SELECTED_PROFILE_NAMES+=("$profile")
    fi
done

if [[ ${#SELECTED_PROFILE_NAMES[@]} -eq 0 ]]; then
    info "服务 profiles: none（仅部署 NPM 与 Watchtower）"
else
    info "服务 profiles: ${SELECTED_PROFILE_NAMES[*]}"
fi

mkdir -p "${STACK_DIR}"

# 为 RSSHub / Browserless 生成共享随机令牌，仅保存在服务器上；重跑时复用。
ensure_browserless_env() {
    local env_file=$1 token temp_file

    if [[ -e "$env_file" ]]; then
        if [[ $(wc -l < "$env_file") -ne 1 ]] || \
           ! grep -qxE 'BROWSERLESS_TOKEN=[0-9a-f]{64}' "$env_file"; then
            error "Browserless 令牌文件格式无效，请检查文件（不要公开其内容）: $env_file"
            return 1
        fi
        chmod 0600 "$env_file"
        return 0
    fi

    token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    if [[ ! "$token" =~ ^[0-9a-f]{64}$ ]]; then
        error "Browserless 随机令牌生成失败，未启动服务"
        return 1
    fi
    temp_file=$(mktemp "${env_file}.XXXXXX")
    printf 'BROWSERLESS_TOKEN=%s\n' "$token" > "$temp_file"
    chmod 0600 "$temp_file"
    mv -f -- "$temp_file" "$env_file"
}

BROWSERLESS_ENV_FILE="${STACK_DIR}/.browserless.env"
ensure_browserless_env "$BROWSERLESS_ENV_FILE"
# 防止父进程的同名环境变量覆盖本次部署保存的令牌。
unset BROWSERLESS_TOKEN
COMPOSE_ENV_ARGS=(--env-file "$BROWSERLESS_ENV_FILE")
info "Browserless 随机令牌已就绪（保存在服务器上，不输出令牌）"

cat > "${STACK_DIR}/docker-compose.yml" << 'COMPOSE_EOF'
# 容器日志限制由 /etc/docker/daemon.json 全局配置，无需逐服务设置
services:

  # ==================== 网络与证书管理 ====================
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
  # ==================== 自动化更新 ====================
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/localtime:/etc/localtime:ro
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
  # ==================== 个人导航与工具 ====================
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    profiles: ["tools"]
    volumes:
      - ./homepage:/app/config
    environment:
      - HOMEPAGE_ALLOWED_HOSTS=__HOMEPAGE_HOST__

  it-tools:
    image: ghcr.io/corentinth/it-tools:latest
    container_name: it-tools
    restart: unless-stopped
    profiles: ["tools"]

  # ==================== 代码托管 ====================
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    restart: unless-stopped
    profiles: ["code"]
    environment:
      - USER_UID=1000
      - USER_GID=1000
    ports:
      - "222:22"
    volumes:
      - ./gitea/data:/data
      - /etc/localtime:/etc/localtime:ro
  # ==================== 媒体与下载 ====================
  navidrome:
    image: deluan/navidrome:latest
    container_name: navidrome
    restart: unless-stopped
    profiles: ["media"]
    volumes:
      - ./navidrome/data:/data
      - /Music:/music:ro

  metube:
    image: ghcr.io/alexta69/metube
    container_name: metube
    restart: unless-stopped
    profiles: ["media"]
    volumes:
      - ./metube/downloads:/downloads

  # ==================== RSS 系统 ====================
  rsshub:
    image: diygod/rsshub:latest
    container_name: rsshub
    restart: always
    profiles: ["rss"]
    environment:
      NODE_ENV: production
      CACHE_TYPE: redis
      REDIS_URL: 'redis://redis:6379/'
      PUPPETEER_WS_ENDPOINT: 'ws://browserless:3000?token=${BROWSERLESS_TOKEN:?BROWSERLESS_TOKEN is required}'
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:1200/healthz']
      interval: 30s
      timeout: 10s
      retries: 3
    depends_on:
      - redis
      - browserless

  browserless:
    # browserless/chrome (v1) 已停止维护，改用 v2 chromium 镜像
    image: ghcr.io/browserless/chromium:latest
    container_name: browserless
    restart: always
    profiles: ["rss"]
    mem_limit: 768m
    cpus: "1.0"
    environment:
      # 与 RSSHub 共享部署时生成的随机令牌（仅容器内网使用）
      - TOKEN=${BROWSERLESS_TOKEN:?BROWSERLESS_TOKEN is required}
    ulimits:
      core:
        hard: 0
        soft: 0

  redis:
    image: redis:alpine
    container_name: redis
    restart: always
    profiles: ["rss"]
    volumes:
      - redis-data:/data
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 5s

  # ==================== 文件管理 ====================
  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    profiles: ["files"]
    # 需要管理宿主机 /root；不放宽 /root 的文件权限。
    user: "0:0"
    volumes:
      - /root:/srv
      - ./Filebrowser/database:/database
      - ./Filebrowser/config:/config
    restart: unless-stopped

  openlist:
    image: openlistteam/openlist:latest
    container_name: openlist
    profiles: ["files"]
    user: "0:0"
    restart: unless-stopped
    volumes:
      - /OpenList:/opt/openlist/data
    environment:
      - UMASK=022
  # ==================== 监控系统 ====================
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    restart: unless-stopped
    profiles: ["monitoring"]
    volumes:
      - ./uptime-kuma/data:/app/data
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    profiles: ["monitoring"]
    environment:
      - APP_URL=http://localhost:8090
    volumes:
      - ./beszel/data:/beszel_data
  # ==================== 笔记系统 ====================
  memos:
    image: neosmemo/memos:latest
    container_name: memos
    restart: unless-stopped
    profiles: ["notes"]
    volumes:
      - ./memos/data:/var/opt/memos
  # ==================== RustDesk 远程桌面 ====================
  hbbs:
    container_name: hbbs
    image: rustdesk/rustdesk-server:latest
    command: hbbs
    profiles: ["rustdesk"]
    volumes:
      - ./rustdesk/data:/root
    network_mode: "host"
    depends_on:
      - hbbr
    restart: unless-stopped
  hbbr:
    container_name: hbbr
    image: rustdesk/rustdesk-server:latest
    command: hbbr
    profiles: ["rustdesk"]
    volumes:
      - ./rustdesk/data:/root
    network_mode: "host"
    restart: unless-stopped
volumes:
  redis-data:

networks:
  default:
    driver: bridge
COMPOSE_EOF

# 域名已通过严格校验，可安全替换占位符
sed -i "s|__HOMEPAGE_HOST__|${HOMEPAGE_HOST}|g" "${STACK_DIR}/docker-compose.yml"

if ! docker compose "${COMPOSE_ENV_ARGS[@]}" -f "${STACK_DIR}/docker-compose.yml" config -q; then
    error "docker-compose.yml 校验失败，未拉取镜像或启动服务"
    exit 1
fi
info "docker-compose.yml 已生成并通过校验: ${STACK_DIR}/docker-compose.yml"

# ---------- 5. 拉取镜像 & 启动服务 ----------
step "5/5 拉取镜像 & 启动服务"

cd "${STACK_DIR}"

info "开始拉取所选服务镜像（任何镜像失败都会停止部署）..."
docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_PROFILE_ARGS[@]}" pull

info "启动基础组件及所选 profile 服务..."
docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_PROFILE_ARGS[@]}" up -d

# 等待容器初始化
info "等待容器启动（10 秒）..."
sleep 10

# File Browser 的随机管理员密码只在首次初始化日志中出现一次
if [[ -n "${ENABLED_PROFILES[files]+x}" ]]; then
    FILEBROWSER_PASSWORD_LINE=""
    for _ in {1..15}; do
        FILEBROWSER_PASSWORD_LINE=$(docker compose "${COMPOSE_ENV_ARGS[@]}" --no-color "${COMPOSE_PROFILE_ARGS[@]}" logs filebrowser 2>/dev/null \
            | grep -iE 'randomly generated password|admin.*password|password.*admin' \
            | tail -1 || true)
        [[ -n "${FILEBROWSER_PASSWORD_LINE}" ]] && break
        sleep 2
    done

    if [[ -n "${FILEBROWSER_PASSWORD_LINE}" ]]; then
        echo ""
        info "File Browser 首次管理员密码（用户 admin，请立即保存并修改）："
        echo "  ${FILEBROWSER_PASSWORD_LINE}"
    else
        warn "未在日志中找到 File Browser 首次密码（已有数据库时不会再次生成）"
        warn "如为首次部署，请检查: cd ${STACK_DIR} && docker compose --env-file .browserless.env logs filebrowser"
    fi
fi

echo ""
step "部署完成"

echo ""
info "所有配置已完成，以下为当前状态："
echo ""
echo "  主机名:          $(hostname)"
echo "  Docker:          $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
echo "  Compose:         $(docker compose version --short 2>/dev/null)"
echo "  自动安全更新:    $(systemctl is-active unattended-upgrades 2>/dev/null)"
echo "  journal 上限:    $(grep -oP 'SystemMaxUse=\K.*' /etc/systemd/journald.conf.d/limit.conf 2>/dev/null || echo '未设置')"
echo "  工作目录:        ${STACK_DIR}"
echo ""

# 容器运行状态检测
info "容器运行状态检测："
echo ""

TOTAL=0
RUNNING=0
FAILED_LIST=""

# 用纯字段格式避免表头干扰
PS_OUTPUT=$(docker compose "${COMPOSE_ENV_ARGS[@]}" ps -a --format "{{.Name}} {{.State}}" 2>/dev/null || true)

if [[ -z "$PS_OUTPUT" ]]; then
    error "未检测到任何容器，部署可能完全失败"
    error "排查命令: cd ${STACK_DIR} && docker compose --env-file .browserless.env logs"
else
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        NAME=$(echo "$line" | awk '{print $1}')
        STATE=$(echo "$line" | awk '{print $2}')
        TOTAL=$((TOTAL + 1))
        if [[ "$STATE" == "running" ]]; then
            RUNNING=$((RUNNING + 1))
            echo -e "  ${GREEN}✔${NC} ${NAME}"
        else
            FAILED_LIST="${FAILED_LIST}  ${RED}✘${NC} ${NAME} (${STATE})\n"
        fi
    done <<< "$PS_OUTPUT"

    if [[ -n "$FAILED_LIST" ]]; then
        echo -e "$FAILED_LIST"
    fi

    echo ""
    if [[ $TOTAL -eq $RUNNING ]]; then
        info "全部 ${TOTAL} 个容器运行正常"
    elif [[ $RUNNING -gt 0 ]]; then
        warn "${RUNNING}/${TOTAL} 个容器运行正常，$(( TOTAL - RUNNING )) 个异常"
        warn "排查命令: cd ${STACK_DIR} && docker compose --env-file .browserless.env logs <容器名>"
    else
        error "所有容器均未正常启动，请检查: cd ${STACK_DIR} && docker compose --env-file .browserless.env logs"
    fi
fi
echo ""

echo -e "${CYAN}====== 部署后待办 ======${NC}"
echo ""
echo "  1. Nginx Proxy Manager"
echo "     访问 http://<服务器IP>:81"
echo "     默认账号: admin@example.com / changeme"
echo ""
echo "  2. 各服务默认端口（通过 NPM 反向代理访问）"
echo "     Homepage:      3000    OpenList:       5244"
echo "     IT-Tools:      80      File Browser:   80"
echo "     Gitea:         3000    Uptime Kuma:    3001"
echo "     Navidrome:     4533    Beszel Hub:     8090"
echo "     Metube:        8081    Memos:          5230"
echo "     RSSHub:        1200"
echo ""
echo "  3. ghcr.io 镜像拉取失败？"
echo "     如 homepage / it-tools / metube 拉取超时，可手动配置 ghcr.io 代理"
echo "     或在 daemon.json 中添加对应加速地址后重新 docker compose --env-file .browserless.env pull"
echo ""
