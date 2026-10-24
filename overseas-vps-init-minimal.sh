#!/bin/bash
# ============================================================
# 境外 VPS 一键初始化脚本（精简版 / 无 sing-box & NextTrace）
# 适用系统：Debian 11+ / Ubuntu 22.04+
# 适用场景：1C1G 精品线路（CN2 GIA / CMI / IIJ）
# 内容：主机名 + 系统更新 + TCP 调优 + fail2ban + 自动安全更新 + 日志限制
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

    (( ${#hostname} >= 1 && ${#hostname} <= 64 )) || return 1
    [[ "$hostname" != .* && "$hostname" != *. && "$hostname" != *".."* ]] || return 1

    IFS='.' read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

# ---------- 前置检查 ----------
if [[ $EUID -ne 0 ]]; then
    error "请以 root 用户运行此脚本"
    exit 1
fi

if ! grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null; then
    error "此脚本仅支持 Debian / Ubuntu 系统"
    exit 1
fi

# ---------- 1. 修改主机名 ----------
step "1/6 修改主机名"
# 使用 Readline 从 /dev/tty 读取，支持退格、Delete 和方向键。
while true; do
    read_tty NEW_HOSTNAME "请输入新主机名（直接回车跳过）: " ""
    if [[ -z "$NEW_HOSTNAME" ]]; then
        warn "跳过主机名修改"
        break
    fi

    if ! valid_hostname "$NEW_HOSTNAME"; then
        warn "主机名格式无效：每段限 1-63 个字母、数字或连字符，且不能以连字符开头/结尾"
        continue
    fi

    HOSTS_NAMES="$NEW_HOSTNAME"
    SHORT_HOSTNAME="${NEW_HOSTNAME%%.*}"
    if [[ "$SHORT_HOSTNAME" != "$NEW_HOSTNAME" ]]; then
        HOSTS_NAMES+=" $SHORT_HOSTNAME"
    fi

    if [[ -f /etc/hosts ]]; then
        cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    fi
    hostnamectl set-hostname "$NEW_HOSTNAME"

    # 防止云镜像的 cloud-init 在重启后恢复云厂商下发的旧主机名。
    if command -v cloud-init &>/dev/null; then
        install -d -m 0755 /etc/cloud/cloud.cfg.d
        printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-vps-preserve-hostname.cfg
    fi

    # FQDN 在前、短主机名在后，避免 sudo 报 "unable to resolve host"。
    if grep -qE '^127\.0\.1\.1([[:space:]]|$)' /etc/hosts; then
        sed -i -E "s/^127\.0\.1\.1([[:space:]]|$).*/127.0.1.1\t${HOSTS_NAMES}/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$HOSTS_NAMES" >> /etc/hosts
    fi
    info "主机名已设置为: $NEW_HOSTNAME（/etc/hosts 已同步）"
    break
done

# ---------- 2. 系统更新 & 安装基础工具 ----------
step "2/6 系统更新 & 安装基础工具"
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
apt-get install -y fail2ban python3-systemd iperf3 cron curl wget ca-certificates tar unattended-upgrades
info "系统更新及基础工具安装完成"

step "终端美化：Starship（Bash）"
configure_starship

# ---------- 3. TCP 调优 ----------
step "3/6 TCP 调优 (sysctl)"

# 尝试加载 BBR 与 fq；内核不支持 BBR 时保留当前拥塞控制算法，不写入无效配置。
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
else
    TCP_CC="${CURRENT_CC:-cubic}"
    warn "当前内核未提供 BBR，将保留拥塞控制算法: $TCP_CC"
fi

# /etc/sysctl.conf 会在 sysctl --system 的最后阶段加载。仅注释本脚本真正接管的
# 同名键，避免旧版脚本那样误改转发、防火墙或云厂商的其他网络参数。
SYSCTL_KEYS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.core.somaxconn
    net.ipv4.tcp_max_syn_backlog
    net.core.netdev_max_backlog
    net.ipv4.tcp_keepalive_time
    net.ipv4.tcp_keepalive_intvl
    net.ipv4.tcp_keepalive_probes
    net.ipv4.tcp_syncookies
    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_ecn
    net.ipv4.ip_local_port_range
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.core.rmem_max
    net.core.wmem_max
    vm.swappiness
)
SYSCTL_BACKED_UP=false
if [[ -f /etc/sysctl.conf ]]; then
    for key in "${SYSCTL_KEYS[@]}"; do
        escaped_key=${key//./\\.}
        if grep -qE "^[[:space:]]*${escaped_key}[[:space:]]*=" /etc/sysctl.conf; then
            if [[ "$SYSCTL_BACKED_UP" == false ]]; then
                cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
                SYSCTL_BACKED_UP=true
            fi
            sed -i -E "s|^[[:space:]]*(${escaped_key})[[:space:]]*=|# [vps-tuning 已接管] &|" /etc/sysctl.conf
        fi
    done
    [[ "$SYSCTL_BACKED_UP" == true ]] && info "已备份 sysctl.conf，并仅注释与本配置冲突的同名参数"
fi

cat > /etc/sysctl.d/99-vps-tuning.conf << SYSCTL_EOF
# ============================================================
# VPS TCP 调优 - 精品线路配置
# 适用：低延迟、低丢包线路；机器规格：1C1G+
# ============================================================

# ---------- 拥塞控制 ----------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${TCP_CC}

# ---------- 连接队列 ----------
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 4096

# ---------- Keepalive ----------
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ---------- 基础保护与路径兼容 ----------
net.ipv4.tcp_syncookies = 1
# 仅在检测到 ICMP 黑洞时启用 PLPMTUD；避免 mode=2 强制从较小 MSS 开始探测。
net.ipv4.tcp_mtu_probing = 1
# 仅被动接受对端 ECN，不主动请求，兼顾兼容性。
net.ipv4.tcp_ecn = 2

# ---------- 出站端口 ----------
net.ipv4.ip_local_port_range = 10000 65535

# ---------- TCP 自动调节缓冲区上限 ----------
# max 是上限而非预分配；不覆盖 tcp_mem/udp_mem，让内核按实际内存自动计算全局水位。
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# ---------- 内存行为 ----------
vm.swappiness = 10
SYSCTL_EOF

if ! SYSCTL_OUTPUT=$(sysctl -p /etc/sysctl.d/99-vps-tuning.conf 2>&1); then
    error "TCP 调优应用失败："
    printf '%s\n' "$SYSCTL_OUTPUT" >&2
    exit 1
fi
info "TCP 调优已应用（写入 /etc/sysctl.d/99-vps-tuning.conf）"

# 验证最终使用的拥塞控制算法
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if [[ "$TCP_CC" == "bbr" && "$CURRENT_CC" == "bbr" ]]; then
    info "BBR 已成功启用"
else
    warn "当前拥塞控制算法: ${CURRENT_CC:-未知}"
fi

# ---------- 配置 iperf3 后台服务 ----------
# 可在运行脚本前通过 IPERF3_PORT 环境变量修改端口；DynamicUser 需要非特权端口。
IPERF3_PORT="${IPERF3_PORT:-5201}"
if [[ ! "$IPERF3_PORT" =~ ^[1-9][0-9]{3,4}$ ]] || (( IPERF3_PORT < 1024 || IPERF3_PORT > 65535 )); then
    error "IPERF3_PORT 必须是 1024-65535 之间的整数（当前: $IPERF3_PORT）"
    exit 1
fi

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

# ---------- 4. 配置 fail2ban ----------
step "4/6 配置 fail2ban"

install -d -m 0755 /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d

# 使用最后加载的 .local drop-in，不覆盖用户已有 jail.local；已有 ignoreip 也会保留。
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

# ---------- 5. 自动安全更新 ----------
step "5/6 配置自动安全更新 (unattended-upgrades)"

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

# ---------- 6. 日志大小限制 ----------
step "6/6 限制 journald 日志大小"

# drop-in 方式，不修改主配置文件
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/limit.conf << 'EOF'
[Journal]
SystemMaxUse=100M
EOF
systemctl restart systemd-journald
info "journald 日志上限已设为 100M"

# ---------- 完成 ----------
step "完成"

echo ""
info "所有配置已完成，以下为当前状态："
echo ""
echo "  主机名:       $(hostname)"
echo "  内核:         $(uname -r)"
echo "  iperf3 服务:  $(systemctl is-active iperf3-server.service 2>/dev/null)（TCP/UDP $IPERF3_PORT）"
echo "  BBR 状态:     $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  fail2ban:     $(systemctl is-active fail2ban 2>/dev/null)"
echo "  自动安全更新: $(systemctl is-active unattended-upgrades 2>/dev/null)"
echo "  journal 上限: $(grep -oP 'SystemMaxUse=\K.*' /etc/systemd/journald.conf.d/limit.conf 2>/dev/null || echo '未设置')"
echo ""
info "建议重启一次使所有配置完全生效: reboot"
