#!/bin/bash
# ============================================================
# VPS 一键初始化脚本（整合入口，单文件独立运行）
# 适用系统：Debian 11+ / Ubuntu 22.04+
# 按序号选择线路与组件；公共步骤仅执行一次。原独立版本保留供迁移核对。
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

# 始终从控制终端读取交互输入，避免 curl | bash 时误读脚本管道。
# -e 启用 Readline，支持退格、Delete 和方向键编辑。
read_tty() {
    local target_var=$1
    local prompt=$2
    local default_value=${3-}
    local reply="$default_value"
    local tty_fd

    if { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
        if ! IFS= read -e -r -p "$prompt" reply <&"$tty_fd"; then
            reply="$default_value"
        fi
        exec {tty_fd}>&-
    else
        warn "未检测到可交互终端，将使用默认值"
    fi

    printf -v "$target_var" '%s' "$reply"
}

valid_hostname() {
    local hostname=$1
    local label
    local -a labels

    (( ${#hostname} >= 1 && ${#hostname} <= 253 )) || return 1
    [[ "$hostname" != .* && "$hostname" != *. && "$hostname" != *".."* ]] || return 1

    IFS='.' read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

is_valid_domain() {
    local domain="$1" label
    local -a labels=()

    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != .* && "$domain" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}


# ---------- 场景与组件选择（不修改系统） ----------
die() { error "$1" >&2; exit 1; }

require_choice() {
    local variable=$1 prompt=$2 fallback=${3-}
    if [[ -z "${!variable:-}" ]]; then
        read_tty "$variable" "$prompt" "$fallback"
        [[ -n "${!variable}" ]] || die "缺少 $variable，请在交互终端选择或通过环境变量提供"
    fi
}

select_scene() {
    echo '请选择初始化场景：'
    echo '  1) HK / JP 低延迟精品线路'
    echo '  2) LA 等高延迟、长距离大带宽线路'
    echo '  3) DE / 法兰克福线路（保留专用 TCP 参数）'
    echo '  4) 精简基础版（低延迟参数，无 sing-box / NextTrace）'
    echo '  5) 国内 Docker / Compose 自托管服务'
    echo '  0) 退出'
    require_choice VPS_SCENE '请输入场景序号: '
    case "$VPS_SCENE" in
        0) exit 0 ;;
        1|hk|jp) VPS_SCENE=hk; SCENE_NAME='HK / JP 精品线路' ;;
        2|la) VPS_SCENE=la; SCENE_NAME='LA 高延迟线路' ;;
        3|de) VPS_SCENE=de; SCENE_NAME='DE / 法兰克福线路' ;;
        4|minimal) VPS_SCENE=minimal; SCENE_NAME='精简基础版' ;;
        5|domestic) VPS_SCENE=domestic; SCENE_NAME='国内自托管服务' ;;
        *) die '场景无效：请输入 0-5 或 hk/la/de/minimal/domestic' ;;
    esac
}

select_components() {
    if [[ "$VPS_SCENE" == minimal || "$VPS_SCENE" == domestic ]]; then
        [[ "${VPS_COMPONENTS:-0}" == 0 ]] || die '精简版和国内版不支持 VPS_COMPONENTS；境外工具请选择场景 1-3'
        VPS_COMPONENTS=0
    else
        echo '境外可选组件：0) 均不安装  1) NextTrace  2) sing-box  3) 两者都安装'
        require_choice VPS_COMPONENTS '请输入组件序号（默认 1）: ' 1
        case "$VPS_COMPONENTS" in 0|1|2|3) ;; *) die '组件序号必须为 0-3' ;; esac
    fi
    INSTALL_NEXTTRACE=0
    INSTALL_SING_BOX=0
    case "$VPS_COMPONENTS" in
        1) INSTALL_NEXTTRACE=1 ;;
        2) INSTALL_SING_BOX=1 ;;
        3) INSTALL_NEXTTRACE=1; INSTALL_SING_BOX=1 ;;
    esac
}

select_services() {
    AVAILABLE_PROFILES=(tools code media rss files monitoring notes)
    declare -gA ENABLED_PROFILES=()
    COMPOSE_PROFILE_ARGS=()
    SELECTED_PROFILE_NAMES=()
    local profile selection item
    local -a requested=()
    echo '国内可选服务（NPM + Watchtower 始终部署）：'
    echo '  1) Homepage + IT-Tools   2) Gitea   3) Navidrome + MeTube'
    echo '  4) RSSHub + Browserless + Redis   5) File Browser + OpenList'
    echo '  6) Uptime Kuma + Beszel   7) Memos   8) 全部   0) 仅基础组件'
    require_choice SERVICE_PROFILES '输入序号，多个用逗号分隔（默认 0）: ' 0
    selection=${SERVICE_PROFILES//[[:space:]]/}
    case "$selection" in
        8|all) requested=("${AVAILABLE_PROFILES[@]}") ;;
        0|none) requested=() ;;
        *)
            [[ "$selection" != ,* && "$selection" != *, && "$selection" != *,,* ]] || die '服务选择不能包含空项'
            IFS=',' read -r -a requested <<< "$selection"
            ;;
    esac
    for item in "${requested[@]}"; do
        case "$item" in
            1|tools) profile=tools ;; 2|code) profile=code ;;
            3|media) profile=media ;; 4|rss) profile=rss ;;
            5|files) profile=files ;; 6|monitoring) profile=monitoring ;;
            7|notes) profile=notes ;; *) die "未知服务选项: $item" ;;
        esac
        ENABLED_PROFILES["$profile"]=1
    done
    for profile in "${AVAILABLE_PROFILES[@]}"; do
        if [[ -n "${ENABLED_PROFILES[$profile]+x}" ]]; then
            SELECTED_PROFILE_NAMES+=("$profile")
            COMPOSE_PROFILE_ARGS+=(--profile "$profile")
        fi
    done
}

validate_options() {
    local variable
    for variable in UPGRADE_SYSTEM INSTALL_STARSHIP RESET_STARSHIP_CONFIG; do
        case "${!variable:-0}" in 0|1) ;; *) die "$variable 仅支持 0 或 1" ;; esac
    done
    if [[ "$VPS_SCENE" != domestic ]]; then
        IPERF3_PORT=${IPERF3_PORT:-5201}
        [[ "$IPERF3_PORT" =~ ^[1-9][0-9]{3,4}$ ]] && (( IPERF3_PORT >= 1024 && IPERF3_PORT <= 65535 )) || die 'IPERF3_PORT 必须是 1024-65535 的整数'
    fi
    STACK_DIR=${STACK_DIR:-/opt/stacks}
    [[ "$STACK_DIR" == /* && "$STACK_DIR" != / && "$STACK_DIR" != *$'\n'* ]] || die 'STACK_DIR 必须为非根目录的绝对路径'
    # 默认使用原始镜像源；由部署者提供可信的镜像站 JSON 数组。
    DOCKER_MIRRORS=${DOCKER_MIRRORS:-[]}
}

print_plan() {
    step '执行方案'
    info "场景：$SCENE_NAME"
    info "公共步骤：主机名（可跳过）、APT 更新（系统升级=${UPGRADE_SYSTEM:-1}）、Starship=${INSTALL_STARSHIP:-1}、自动安全更新、journald 100M"
    if [[ "$VPS_SCENE" == domestic ]]; then
        info "Docker / Compose；基础服务 NPM + Watchtower；可选服务：${SELECTED_PROFILE_NAMES[*]:-无}"
        info "服务目录：$STACK_DIR"
    else
        info "TCP 参数方案：$VPS_SCENE；fail2ban；iperf3 端口：$IPERF3_PORT"
        info "安装 NextTrace=$INSTALL_NEXTTRACE，安装 sing-box 及配置其自动更新=$INSTALL_SING_BOX"
    fi
    info '未选择的组件不新装、不卸载，已有服务和定时任务不会因此被移除。'
}

preflight() {
    [[ $EUID -eq 0 ]] || die '请以 root 用户运行此脚本'
    [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release'
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        debian:*) dpkg --compare-versions "$VERSION_ID" ge 11 || die '需要 Debian 11+' ;;
        ubuntu:*) dpkg --compare-versions "$VERSION_ID" ge 22.04 || die '需要 Ubuntu 22.04+' ;;
        *) die '此脚本仅支持 Debian 11+ / Ubuntu 22.04+' ;;
    esac
    [[ -n "${VERSION_CODENAME:-}" ]] || die '缺少系统版本代号 VERSION_CODENAME'
    [[ -d /run/systemd/system ]] || die '需要运行中的 systemd；受限容器仅兼容 TCP 参数跳过，仍须支持 systemd 服务'
}

collect_hostname() {
    NEW_HOSTNAME=${VPS_HOSTNAME:-}
    if [[ -z "$NEW_HOSTNAME" ]]; then
        read_tty NEW_HOSTNAME '请输入新主机名（直接回车跳过）: ' ''
    fi
    [[ -z "$NEW_HOSTNAME" ]] || valid_hostname "$NEW_HOSTNAME" || die '主机名格式无效'
}

collect_homepage() {
    HOMEPAGE_HOST=${HOMEPAGE_HOST:-}
    if [[ -n "${ENABLED_PROFILES[tools]+x}" ]]; then
        require_choice HOMEPAGE_HOST '请输入 Homepage 域名（如 nav.example.com）: '
        is_valid_domain "$HOMEPAGE_HOST" || die 'Homepage 仅允许有效 DNS 域名，不含协议、端口、路径或通配符'
    else
        # 未启用 tools 时不要求私人域名；将来启用前应重新运行并指定域名。
        HOMEPAGE_HOST=nav.example.com
    fi
}

backup_file() {
    local target=$1 backup
    if [[ -f "$target" ]]; then
        backup=$(mktemp "${target}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")
        cp -a -- "$target" "$backup"
    fi
}

configure_hostname() {
step "修改主机名"
[[ -n "$NEW_HOSTNAME" ]] || { info "跳过主机名修改"; return 0; }
    HOSTS_NAMES="$NEW_HOSTNAME"
    SHORT_HOSTNAME="${NEW_HOSTNAME%%.*}"
    if [[ "$SHORT_HOSTNAME" != "$NEW_HOSTNAME" ]]; then
        HOSTS_NAMES+=" $SHORT_HOSTNAME"
    fi

    if [[ -f /etc/hosts ]]; then
        cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    fi
    backup_file /etc/hostname
    backup_file /etc/cloud/cloud.cfg.d/99-vps-preserve-hostname.cfg
    hostnamectl set-hostname "$NEW_HOSTNAME"

    # 防止云镜像的 cloud-init 在重启后恢复云厂商下发的旧主机名。
    if command -v cloud-init &>/dev/null; then
        install -d -m 0755 /etc/cloud/cloud.cfg.d
        printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-vps-preserve-hostname.cfg
    fi

    # FQDN 在前、短主机名在后，避免 sudo 报 "unable to resolve host"。
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOSTS_NAMES}/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$HOSTS_NAMES" >> /etc/hosts
    fi
    info "主机名已设置为: $NEW_HOSTNAME（/etc/hosts 已同步）"
}

install_base() {
# ---------- 2. 系统更新 & 安装基础工具 ----------
step "系统更新 & 安装基础工具"
# 非交互模式：避免 conffile 冲突弹窗和 needrestart 交互卡死脚本
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
# ---------- 更新软件包索引与系统升级 ----------
case "${UPGRADE_SYSTEM:-1}" in
    0|1) ;;
    *) error "UPGRADE_SYSTEM 仅支持 0 或 1"; exit 1 ;;
esac
if ! apt-get update; then
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
apt-get install -y curl wget ca-certificates tar unattended-upgrades
if [[ "$VPS_SCENE" == domestic ]]; then
    apt-get install -y gnupg jq
else
    apt-get install -y fail2ban python3-systemd iperf3 cron kmod
fi
info "系统更新及基础工具安装完成"
}

configure_tcp() {
# ---------- 3. TCP 调优 ----------
step "TCP 调优 ($SCENE_NAME)"

# 尝试加载 BBR 与 fq；容器型 VPS 可能由宿主机统一控制，实例内无法修改。
modprobe tcp_bbr 2>/dev/null || true
modprobe sch_fq 2>/dev/null || true
AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
if grep -qw bbr <<< "$AVAILABLE_CC"; then
    TCP_CC="bbr"
    if modinfo tcp_bbr &>/dev/null; then
        install -d -m 0755 /etc/modules-load.d
        printf '%s\n' tcp_bbr > /etc/modules-load.d/99-vps-bbr.conf
    fi
elif [[ -n "$CURRENT_CC" ]]; then
    TCP_CC="$CURRENT_CC"
    warn "当前内核未提供 BBR，将保留拥塞控制算法: $TCP_CC"
else
    TCP_CC=""
    warn "宿主机未向实例暴露 TCP 拥塞控制接口，无法在实例内启用 BBR"
fi

install -d -m 0755 /etc/sysctl.d
SYSCTL_TARGET=/etc/sysctl.d/99-vps-tuning.conf
backup_file "$SYSCTL_TARGET"
SYSCTL_FILE=$(mktemp /etc/sysctl.d/.vps-tuning.XXXXXX)
APPLIED_SYSCTL_KEYS=()
APPLIED_SYSCTL_COUNT=0
SKIPPED_SYSCTL_COUNT=0

# 只将内核实际暴露且允许写入的参数加入持久化配置。
# 这样在 LXC/OpenVZ 等受限容器中也不会因个别 sysctl 失败而中断整个初始化。
try_sysctl() {
    local key=$1
    local value=$2
    local output

    if ! sysctl -n "$key" >/dev/null 2>&1; then
        warn "跳过 $key：宿主机未暴露该参数"
        ((SKIPPED_SYSCTL_COUNT += 1))
        return 0
    fi

    if ! output=$(sysctl -w "$key=$value" 2>&1); then
        warn "跳过 $key：$output"
        ((SKIPPED_SYSCTL_COUNT += 1))
        return 0
    fi

    printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_FILE"
    APPLIED_SYSCTL_KEYS+=("$key")
    ((APPLIED_SYSCTL_COUNT += 1))
}

cat > "$SYSCTL_FILE" << 'SYSCTL_EOF'
# ============================================================
# VPS TCP 调优 - 整合入口按场景选择的配置
# 参数不会改变实际运营商路由
# 仅包含本机内核实际支持且允许写入的参数
# ============================================================
SYSCTL_EOF

printf '\n# ---------- 拥塞控制 ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.core.default_qdisc fq
if [[ -n "$TCP_CC" ]]; then
    try_sysctl net.ipv4.tcp_congestion_control "$TCP_CC"
fi

printf '\n# ---------- 连接队列 ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.core.somaxconn 4096
try_sysctl net.ipv4.tcp_max_syn_backlog 4096
try_sysctl net.core.netdev_max_backlog 4096

printf '\n# ---------- Keepalive ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.ipv4.tcp_keepalive_time 600
try_sysctl net.ipv4.tcp_keepalive_intvl 30
try_sysctl net.ipv4.tcp_keepalive_probes 5

printf '\n# ---------- 基础保护与路径兼容 ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.ipv4.tcp_syncookies 1
try_sysctl net.ipv4.tcp_mtu_probing 1
try_sysctl net.ipv4.tcp_ecn 2

printf '\n# ---------- 出站端口 ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.ipv4.ip_local_port_range "10000 65535"

printf '\n# ---------- TCP 自动调节缓冲区上限（按场景选择）----------\n' >> "$SYSCTL_FILE"
# 保留原版本的缓冲区差异：HK/精简 16 MiB，LA/DE 32 MiB。
local buffer_max=16777216 wmem_default=65536
[[ "$VPS_SCENE" == hk || "$VPS_SCENE" == minimal ]] || buffer_max=33554432
[[ "$VPS_SCENE" != de ]] || wmem_default=16384
try_sysctl net.ipv4.tcp_rmem "4096 131072 $buffer_max"
try_sysctl net.ipv4.tcp_wmem "4096 $wmem_default $buffer_max"
try_sysctl net.core.rmem_max "$buffer_max"
try_sysctl net.core.wmem_max "$buffer_max"
if [[ "$VPS_SCENE" == de ]]; then
    try_sysctl net.ipv4.tcp_moderate_rcvbuf 1
    try_sysctl net.ipv4.tcp_window_scaling 1
    try_sysctl net.ipv4.tcp_slow_start_after_idle 0
fi

printf '\n# ---------- 内存行为 ----------\n' >> "$SYSCTL_FILE"
try_sysctl vm.swappiness 10

if (( APPLIED_SYSCTL_COUNT == 0 )); then
    rm -f "$SYSCTL_FILE"
    warn "宿主机禁止修改全部目标参数，已跳过 TCP 调优并继续后续初始化"
else
    chmod 0644 "$SYSCTL_FILE"
    mv -f -- "$SYSCTL_FILE" "$SYSCTL_TARGET"
    SYSCTL_FILE=$SYSCTL_TARGET
    info "TCP 调优已应用 $APPLIED_SYSCTL_COUNT 项，跳过 $SKIPPED_SYSCTL_COUNT 项"
    info "仅将成功参数写入 $SYSCTL_FILE"

    # /etc/sysctl.conf 在 sysctl --system 中较晚加载。仅注释已成功接管的同名键。
    SYSCTL_BACKED_UP=false
    if [[ -f /etc/sysctl.conf ]]; then
        for key in "${APPLIED_SYSCTL_KEYS[@]}"; do
            escaped_key=${key//./\\.}
            if grep -qE "^[[:space:]]*${escaped_key}[[:space:]]*=" /etc/sysctl.conf; then
                if [[ "$SYSCTL_BACKED_UP" == false ]]; then
                    cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
                    SYSCTL_BACKED_UP=true
                fi
                sed -i -E "s|^[[:space:]]*(${escaped_key})[[:space:]]*=|# [vps-tuning 已接管] &|" /etc/sysctl.conf
            fi
        done
        [[ "$SYSCTL_BACKED_UP" == true ]] && info "已备份 sysctl.conf，并仅注释成功接管的同名参数"
    fi
fi

# 验证最终使用的拥塞控制算法
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if [[ "$TCP_CC" == "bbr" && "$CURRENT_CC" == "bbr" ]]; then
    info "BBR 已成功启用"
elif [[ -n "$CURRENT_CC" ]]; then
    warn "当前拥塞控制算法: $CURRENT_CC"
else
    warn "无法读取拥塞控制算法；该项由 VPS 宿主机管理"
fi
}

configure_iperf3() {
# ---------- 配置 iperf3 后台服务 ----------
# 可在运行脚本前通过 IPERF3_PORT 环境变量修改端口；DynamicUser 需要非特权端口。
IPERF3_PORT="${IPERF3_PORT:-5201}"
if [[ ! "$IPERF3_PORT" =~ ^[1-9][0-9]{3,4}$ ]] || (( IPERF3_PORT < 1024 || IPERF3_PORT > 65535 )); then
    error "IPERF3_PORT 必须是 1024-65535 之间的整数（当前: $IPERF3_PORT）"
    exit 1
fi

backup_file /etc/systemd/system/iperf3-server.service
cat > /etc/systemd/system/iperf3-server.service << EOF
[Unit]
Description=iperf3 Network Performance Test Server
Documentation=man:iperf3(1)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/iperf3 --server --port ${IPERF3_PORT}
Restart=on-failure
RestartSec=3s
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iperf3-server.service
if ! systemctl restart iperf3-server.service || ! systemctl is-active --quiet iperf3-server.service; then
    error "iperf3 服务启动失败，端口 $IPERF3_PORT 可能已被占用"
    systemctl status iperf3-server.service --no-pager || true
    exit 1
fi
info "iperf3 已在后台运行并设置为开机自启（端口: $IPERF3_PORT）"
warn "iperf3 默认无身份认证，请仅向可信 IP 开放 TCP/UDP $IPERF3_PORT"
}

install_nexttrace() {
# ---------- 4. 安装 NextTrace ----------
step "安装 NextTrace"
if command -v nexttrace &>/dev/null || command -v nxtrace &>/dev/null; then
    warn "NextTrace 已安装，跳过"
else
    run_installer https://nxtrace.org/nt || {
        warn "NextTrace 安装脚本退出码非零，请稍后手动安装"
    }
    if command -v nexttrace &>/dev/null || command -v nxtrace &>/dev/null; then
        info "NextTrace 安装完成"
    else
        warn "NextTrace 未检测到"
    fi
fi
}

install_singbox() {
# ---------- 5. 安装 sing-box ----------
step "安装 sing-box"
if command -v sing-box &>/dev/null || [[ -f /usr/local/bin/sb ]]; then
    SB_VER=$(sing-box version 2>/dev/null || echo '未知版本')
    warn "sing-box 已安装 (${SB_VER})，跳过"
else
    run_installer https://github.com/233boy/sing-box/raw/main/install.sh || {
        warn "sing-box 安装脚本退出码非零（可能是用户取消），继续执行后续步骤"
    }
    if command -v sing-box &>/dev/null; then
        info "sing-box 安装完成"
    else
        warn "sing-box 未检测到，请稍后手动安装"
    fi
fi
}

configure_fail2ban() {
# ---------- 6. 配置 fail2ban ----------
step "配置 fail2ban"

install -d -m 0755 /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d

# 使用最后加载的 .local drop-in，不覆盖用户已有 jail.local；已有 ignoreip 也会保留。
backup_file /etc/fail2ban/jail.d/99-vps-sshd.local
cat > /etc/fail2ban/jail.d/99-vps-sshd.local << 'EOF'
[DEFAULT]
ignoreself = true
usedns = no

# 首次封 1 小时；重复攻击自动按 1、2、4... 倍递增，最长 7 天。
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5

[sshd]
enabled = true
# 统一从 journald 读取 SSH 日志，兼容没有 /var/log/auth.log 的精简系统。
backend = systemd
# 封禁来源的所有端口，兼容自定义 SSH 端口。
banaction = %(banaction_allports)s
EOF

# 数据库保留 30 天，足以支持递增封禁，同时避免永久增长。
backup_file /etc/fail2ban/fail2ban.d/99-vps-local.local
cat > /etc/fail2ban/fail2ban.d/99-vps-local.local << 'EOF'
[Definition]
dbpurgeage = 2592000
EOF

if ! fail2ban-client -t; then
    error "fail2ban 配置校验失败，未重启服务"
    exit 1
fi
systemctl enable fail2ban
if ! systemctl restart fail2ban || ! systemctl is-active --quiet fail2ban; then
    error "fail2ban 启动失败，安全防护未生效"
    systemctl status fail2ban --no-pager || true
    exit 1
fi
info "fail2ban 已配置并启动（SSH 递增封禁，最长 7 天）"
}

configure_sb_update() {
# ---------- 7. 构建 sing-box 自动更新脚本 ----------
step "构建 sing-box 自动更新脚本"

if [[ -f /usr/local/bin/sb ]]; then
    backup_file /usr/local/bin/sb-auto-update.sh
    cat > /usr/local/bin/sb-auto-update.sh << 'SCRIPT_EOF'
#!/bin/bash
set -uo pipefail

# sing-box 自动更新脚本
# 更新顺序：脚本 -> 内核 -> caddy（如有）

LOG_FILE="/var/log/sb-update.log"
LOCK_FILE="/run/lock/sb-auto-update.lock"
SB_BIN="/usr/local/bin/sb"
MAX_LOG_BYTES=$((5 * 1024 * 1024))

rotate_log() {
    local log_size=0
    if [[ -f "$LOG_FILE" ]]; then
        log_size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)
        if (( log_size >= MAX_LOG_BYTES )); then
            mv -f "$LOG_FILE" "${LOG_FILE}.1"
        fi
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

run_update() {
    local description=$1
    shift
    log "$description..."
    if "$@" >> "$LOG_FILE" 2>&1; then
        log "$description：成功"
    else
        log "$description：失败"
        UPDATE_FAILED=1
    fi
}

rotate_log
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "已有更新任务正在运行，本次跳过"
    exit 0
fi

UPDATE_FAILED=0
log "========== 开始更新 =========="
run_update "更新 sb 脚本" "$SB_BIN" update sh
run_update "更新 sing-box 内核" "$SB_BIN" update core

if command -v caddy >/dev/null 2>&1; then
    run_update "更新 caddy" "$SB_BIN" update caddy
else
    log "未检测到 caddy，跳过"
fi

if (( UPDATE_FAILED != 0 )); then
    log "========== 更新结束（存在失败，请检查日志）=========="
    echo "" >> "$LOG_FILE"
    exit 1
fi

log "========== 更新完成 =========="
echo "" >> "$LOG_FILE"
SCRIPT_EOF

    chmod +x /usr/local/bin/sb-auto-update.sh

    # 非交互式写入 crontab（幂等：先删旧条目再添加）
    EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v 'sb-auto-update' || true)
    echo "${EXISTING_CRON}
0 4 * * * /usr/local/bin/sb-auto-update.sh" | crontab -

    systemctl enable --now cron
    info "sing-box 自动更新脚本已部署（每天 04:00 执行）"
else
    warn "未检测到 /usr/local/bin/sb，跳过自动更新脚本部署"
fi
}

configure_security() {
# ---------- 8. 自动安全更新 ----------
step "配置自动安全更新 (unattended-upgrades)"

backup_file /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

backup_file /etc/apt/apt.conf.d/50unattended-upgrades
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

# ---------- 9. 日志大小限制 ----------
step "限制 journald 日志大小"

# drop-in 方式，不修改主配置文件
mkdir -p /etc/systemd/journald.conf.d
backup_file /etc/systemd/journald.conf.d/limit.conf
cat > /etc/systemd/journald.conf.d/limit.conf << 'EOF'
[Journal]
SystemMaxUse=100M
EOF
systemctl restart systemd-journald
info "journald 日志上限已设为 100M"
}

install_docker() {
# ---------- 3. 安装 Docker & Compose ----------
step "安装 Docker & Compose"

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

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    info "Docker 安装完成: $(docker --version)"
fi

systemctl enable --now docker

# 只使用部署者显式提供的镜像站；未提供时保留现有 mirrors。
jq -e 'type == "array" and all(.[]; type == "string" and test("^https?://[^[:space:]]+$"))' <<< "$DOCKER_MIRRORS" >/dev/null || die 'DOCKER_MIRRORS 必须为 HTTP(S) 地址的 JSON 数组'
# 配置 Docker daemon（可选镜像加速 + 日志限制）
mkdir -p /etc/docker
# 将本脚本的配置合并到现有 daemon.json；写入前校验，重启失败则回滚
DAEMON_FILE="/etc/docker/daemon.json"
DAEMON_BACKUP=""
DAEMON_FRAGMENT=$(mktemp /etc/docker/daemon.fragment.XXXXXX)
DAEMON_CANDIDATE=$(mktemp /etc/docker/daemon.candidate.XXXXXX)

cat > "${DAEMON_FRAGMENT}" << DAEMON_EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    }
}
DAEMON_EOF

if [[ "$DOCKER_MIRRORS" != '[]' ]]; then
    jq --argjson mirrors "$DOCKER_MIRRORS" '. + {"registry-mirrors": $mirrors}' "$DAEMON_FRAGMENT" > "$DAEMON_CANDIDATE"
    cp "$DAEMON_CANDIDATE" "$DAEMON_FRAGMENT"
fi

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
info "Docker daemon 已合并配置（按需设置镜像站 + 全局日志限制）"

# 验证 compose 插件
if docker compose version &>/dev/null; then
    info "Docker Compose 就绪: $(docker compose version --short)"
else
    error "Docker Compose 插件未安装，请检查 Docker 版本"
    exit 1
fi
}

deploy_services() {
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
ensure_browserless_env "$BROWSERLESS_ENV_FILE" || die 'Browserless 令牌文件不可用，停止部署'
# 防止父进程的同名环境变量覆盖本次部署保存的令牌。
unset BROWSERLESS_TOKEN
COMPOSE_ENV_ARGS=(--env-file "$BROWSERLESS_ENV_FILE" -f "${STACK_DIR}/docker-compose.yml")
info "Browserless 随机令牌已就绪（保存在服务器上，不输出令牌）"

COMPOSE_TARGET="${STACK_DIR}/docker-compose.yml"
COMPOSE_CANDIDATE=$(mktemp "${STACK_DIR}/.compose-candidate.XXXXXX")
cat > "$COMPOSE_CANDIDATE" << 'COMPOSE_EOF'
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
      - ./music:/music:ro

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
      - ./openlist/data:/opt/openlist/data
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
volumes:
  redis-data:

networks:
  default:
    driver: bridge
COMPOSE_EOF

# 域名已通过严格校验，可安全替换占位符
sed -i "s|__HOMEPAGE_HOST__|${HOMEPAGE_HOST}|g" "$COMPOSE_CANDIDATE"

if ! docker compose --env-file "$BROWSERLESS_ENV_FILE" --project-directory "$STACK_DIR" -f "$COMPOSE_CANDIDATE" "${COMPOSE_PROFILE_ARGS[@]}" config -q; then
    rm -f -- "$COMPOSE_CANDIDATE"
    error "docker-compose.yml 校验失败，保留原文件，未拉取镜像或启动服务"
    exit 1
fi
backup_file "$COMPOSE_TARGET"
mv -f -- "$COMPOSE_CANDIDATE" "$COMPOSE_TARGET"
info "docker-compose.yml 已生成并通过校验: $COMPOSE_TARGET"

# ---------- 5. 拉取镜像 & 启动服务 ----------
step "拉取镜像 & 启动服务"

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
PS_OUTPUT=$(docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_PROFILE_ARGS[@]}" ps -a --format "{{.Name}} {{.State}}" 2>/dev/null || true)

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
echo "     首次登录凭据请查所用镜像版本说明，登录后立即修改"
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
}

# 第三方安装程序先完整下载并检查 Bash 语法，下载失败不得执行部分内容。
run_installer() (
    local installer
    installer=$(mktemp)
    trap 'rm -f -- "$installer"' EXIT
    curl -fsSL "$1" -o "$installer" || return 1
    [[ -s "$installer" ]] && bash -n "$installer" || return 1
    bash "$installer"
)

show_help() {
    cat <<'HELP'
用法：bash vps-init.sh [--plan | --help]
  --plan  选择并打印方案，不安装软件或修改系统；可在普通用户下执行。
  --help  显示帮助。
场景：VPS_SCENE=1/2/3/4/5 或 hk/la/de/minimal/domestic；0=退出。
境外组件：VPS_COMPONENTS=0 无 / 1 NextTrace（默认）/ 2 sing-box / 3 两者。
国内服务：SERVICE_PROFILES=1,4,6 等，0/none=基础（默认），8/all=全部。
其他变量：VPS_HOSTNAME、UPGRADE_SYSTEM、INSTALL_STARSHIP、RESET_STARSHIP_CONFIG、
          IPERF3_PORT、HOMEPAGE_HOST、STACK_DIR、DOCKER_MIRRORS。
HELP
}

main() {
    local plan_only=0
    case "${1:-}" in
        --help|-h) show_help; return 0 ;;
        --plan) plan_only=1 ;;
        '') ;;
        *) die '未知参数，使用 --help 查看用法' ;;
    esac
    (( $# <= 1 )) || die '参数过多，使用 --help 查看用法'
    select_scene
    select_components
    if [[ "$VPS_SCENE" == domestic ]]; then select_services; fi
    validate_options
    print_plan
    (( plan_only == 0 )) || return 0
    preflight
    collect_hostname
    if [[ "$VPS_SCENE" == domestic ]]; then collect_homepage; fi
    configure_hostname
    install_base
    step '终端美化：Starship（Bash）'
    configure_starship
    configure_security
    if [[ "$VPS_SCENE" == domestic ]]; then
        install_docker
        deploy_services
    else
        configure_tcp
        configure_iperf3
        configure_fail2ban
        if [[ "$INSTALL_NEXTTRACE" == 1 ]]; then install_nexttrace; fi
        if [[ "$INSTALL_SING_BOX" == 1 ]]; then
            install_singbox
            configure_sb_update
        fi
        step '初始化完成'
        info "场景：$SCENE_NAME；拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '由宿主机管理')"
        info "iperf3：$(systemctl is-active iperf3-server.service 2>/dev/null || true)；fail2ban：$(systemctl is-active fail2ban 2>/dev/null || true)"
        info '建议维护窗口内重启一次：reboot；Starship 重新连接 SSH 后生效。'
    fi
}

# 被隔离测试 source 时只加载函数；正常执行（含 bash <(curl ...)）才进入 main。
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
