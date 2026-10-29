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

    # read 成功读到空行时也应用默认值；主机名等空默认值仍保持为空。
    printf -v "$target_var" '%s' "${reply:-$default_value}"
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

is_valid_domain() {
    local domain="$1" label
    local -a labels=()

    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != .* && "$domain" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}


# ---------- 系统概况与操作选择（不修改系统） ----------
die() { error "$1" >&2; exit 1; }

# 在子 Shell 中读取系统信息，避免 os-release 的变量影响后续部署。
# 所有探测均为本机只读操作；精简系统缺少命令或 /proc 字段时显示“未知”。
print_system_overview() (
    local os_name kernel arch host cpu_count cpu_model memory swap disk uptime_text load virt init_state user_name
    step 'Linux 系统概况'
    kernel=$(uname -r 2>/dev/null || true)
    arch=$(uname -m 2>/dev/null || true)
    host=$(hostname 2>/dev/null || true)
    os_name=$(uname -s 2>/dev/null || true)
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_name=${PRETTY_NAME:-${NAME:-$os_name}}
    fi
    cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    cpu_model=''
    memory='' swap='' uptime_text='' load=''
    if [[ -r /proc/cpuinfo ]]; then
        cpu_model=$(awk -F ': *' '/^(model name|Hardware|Processor)[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
    fi
    if [[ -r /proc/meminfo ]]; then
        memory=$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2; found=1}
            END {if (total>0) {printf "总计 %.0f MiB", total/1024; if (found) printf " / 可用 %.0f MiB", available/1024}}' /proc/meminfo 2>/dev/null || true)
        swap=$(awk '/^SwapTotal:/ {total=$2; found=1} /^SwapFree:/ {free=$2}
            END {if (found) {if (total==0) printf "未配置"; else printf "总计 %.0f MiB / 可用 %.0f MiB", total/1024, free/1024}}' /proc/meminfo 2>/dev/null || true)
    fi
    disk=$(LC_ALL=C df -Pk / 2>/dev/null | awk 'NR==2 {printf "总计 %.1f GiB / 可用 %.1f GiB / 已用 %s", $2/1048576, $4/1048576, $5}' || true)
    if [[ -r /proc/uptime ]]; then
        uptime_text=$(awk '{printf "%d 天 %d 小时 %d 分钟", $1/86400, ($1%86400)/3600, ($1%3600)/60}' /proc/uptime 2>/dev/null || true)
    fi
    if [[ -r /proc/loadavg ]]; then
        load=$(awk '{printf "%s / %s / %s（1 / 5 / 15 分钟）", $1, $2, $3}' /proc/loadavg 2>/dev/null || true)
    fi
    virt=$(systemd-detect-virt 2>/dev/null || true)
    [[ "$virt" != none ]] || virt='未检测到虚拟化'
    init_state='未检测到运行中的 systemd'
    [[ ! -d /run/systemd/system ]] || init_state='systemd 已运行'
    user_name=$(id -un 2>/dev/null || true)
    printf '  主机名称：%s\n' "${host:-未知}"
    printf '  操作系统：%s\n' "${os_name:-未知}"
    printf '  内核架构：%s / %s\n' "${kernel:-未知}" "${arch:-未知}"
    printf '  CPU：%s 逻辑核%s\n' "${cpu_count:-未知}" "${cpu_model:+ / $cpu_model}"
    printf '  内存：%s\n  Swap：%s\n' "${memory:-未知}" "${swap:-未知}"
    printf '  根分区：%s\n' "${disk:-未知}"
    printf '  运行时长：%s\n  系统负载：%s\n' "${uptime_text:-未知}" "${load:-未知}"
    printf '  虚拟化：%s\n  服务管理：%s\n' "${virt:-未知}" "$init_state"
    printf '  当前用户：%s（UID=%s）\n' "${user_name:-未知}" "$EUID"
    info '运行要求：Debian 11+ / Ubuntu 22.04+、root 权限、运行中的 systemd；正式执行前会校验。'
)

mode_label() {
    case "$1" in
        full) printf '完整初始化' ;;
        components) printf '安装 / 调整组件' ;;
        status) printf '查看运行状态（只读）' ;;
        update) printf '更新已有组件 / 服务' ;;
    esac
}

require_choice() {
    local variable=$1 prompt=$2 fallback=${3-}
    if [[ -z "${!variable:-}" ]]; then
        read_tty "$variable" "$prompt" "$fallback"
        [[ -n "${!variable}" ]] || die "缺少 $variable，请在交互终端选择或通过环境变量提供"
    fi
}

select_mode() {
    step '选择操作'
    echo '  1) 完整初始化（默认）'
    echo '     适合新机器：配置系统基础环境，再安装所选工具或服务。'
    echo '  2) 安装 / 调整组件'
    echo '     适合已有机器：补装工具、部署服务组，或调整后台任务。'
    echo '     不做全系统升级，不改主机名、TCP 参数及系统安全策略。'
    echo '  3) 查看运行状态（只读）'
    echo '     检查所选范围的现有服务，不安装或修改配置。'
    echo '  4) 更新已有组件 / 服务'
    echo '     更新已安装工具或拉取服务镜像；沿用已有配置。'
    echo '  0) 退出脚本'
    require_choice VPS_MODE '请选择操作 [0-4，回车=1]: ' 1
    case "$VPS_MODE" in
        0) exit 0 ;;
        1|full) VPS_MODE=full ;;
        2|components) VPS_MODE=components ;;
        3|status) VPS_MODE=status ;;
        4|update) VPS_MODE=update ;;
        *) die '模式无效：请输入 0-4 或 full/components/status/update' ;;
    esac
    info "已选择：$(mode_label "$VPS_MODE")"
}

# iperf3/sing-box 安装模式默认启用；Watchtower 默认保持现状，新装不启用。
# ACTION=0 仍接受显式环境变量，兼容旧自动化；检查/更新模式始终不调整后台任务。

select_background_actions() {
    if [[ "$VPS_MODE" == full || "$VPS_MODE" == components ]]; then
        step '设置后台任务'
        echo '  以下任务独立选择；启用后会持续运行或按计划执行。'
        if [[ "$VPS_SCENE" == domestic ]]; then
        echo '  Watchtower：定时更新所选服务；PostgreSQL、Memos、Komari 不参与。'
            choose_background_action WATCHTOWER_ACTION 'Watchtower 自动更新' 0
        else
            printf '  iperf3：启动网络测速服务，端口 %s；客户端命令：iperf3 -c 服务器地址 -p %s。\n' "${IPERF3_PORT:-5201}" "${IPERF3_PORT:-5201}"
            echo '  此服务无身份认证，请仅向可信 IP 放行端口。'
            choose_background_action IPERF3_ACTION 'iperf3 常驻服务'
            if sb_update_supported; then
                echo '  sing-box：每天 04:00（服务器时区）更新管理脚本与内核。'
                choose_background_action SB_UPDATE_ACTION 'sing-box 定时更新'
            else
                [[ "${SB_UPDATE_ACTION:-0}" != 1 ]] || die '启用定时更新需要已有 sb 管理脚本，或本次选择新装 sing-box'
                info '本次未选择新装 sing-box，或已有内核缺少 sb 管理入口，跳过定时更新选择'
            fi
        fi
    fi
    IPERF3_ACTION=${IPERF3_ACTION:-0}
    WATCHTOWER_ACTION=${WATCHTOWER_ACTION:-0}
    SB_UPDATE_ACTION=${SB_UPDATE_ACTION:-0}
}

sb_update_supported() {
    [[ ! -f /usr/local/bin/sb ]] || return 0
    [[ "${INSTALL_SING_BOX:-0}" == 1 ]] || return 1
    # 原生内核已安装且运行、但没有 233boy 管理入口时，不配置不适用的 sb 定时任务。
    if probe_singbox_installation; then return 1; fi
    return 0
}

probe_background_state() {
    BACKGROUND_PRESENT=0
    BACKGROUND_STATE='未配置'
    local current enabled cron_content
    case "$1" in
        IPERF3_ACTION)
            if systemctl cat iperf3-server.service >/dev/null 2>&1; then
                BACKGROUND_PRESENT=1
                current=$(systemctl is-active iperf3-server.service 2>/dev/null || true)
                enabled=$(systemctl is-enabled iperf3-server.service 2>/dev/null || true)
                if [[ "$current" == active ]]; then BACKGROUND_STATE='运行中'; else BACKGROUND_STATE='未运行'; fi
                if [[ "$enabled" == enabled ]]; then BACKGROUND_STATE+='，已设置开机启动'; else BACKGROUND_STATE+='，未设置开机启动'; fi
            fi
            ;;
        SB_UPDATE_ACTION)
            cron_content=''
            if command -v crontab >/dev/null 2>&1; then
                if ! read_root_crontab; then BACKGROUND_PRESENT=1; BACKGROUND_STATE='无法读取 crontab，任务状态未知'; return 0; fi
                cron_content=$ROOT_CRONTAB_CONTENT
            fi
            if [[ -n "$(filter_sb_update_cron 1 <<< "$cron_content")" ]]; then
                BACKGROUND_PRESENT=1
                BACKGROUND_STATE='已配置定时更新'
            elif [[ -f /usr/local/bin/sb-auto-update.sh ]]; then
                BACKGROUND_PRESENT=1
                BACKGROUND_STATE='更新脚本已存在，未配置定时任务'
            fi
            ;;
        WATCHTOWER_ACTION)
            if command -v docker >/dev/null 2>&1; then
                if current=$(docker inspect --format '{{.State.Status}}' watchtower 2>/dev/null); then
                    BACKGROUND_PRESENT=1
                    case "$current" in
                        running) BACKGROUND_STATE='运行中' ;;
                        restarting) BACKGROUND_STATE='正在重启' ;;
                        *) BACKGROUND_STATE='已配置，未运行' ;;
                    esac
                fi
            fi
            ;;
    esac
}

choose_background_action() {
    local variable=$1 label=$2 default=${3:-1}
    probe_background_state "$variable"
    show_background_menu "$label" "$BACKGROUND_PRESENT" "$BACKGROUND_STATE" "$default"
    require_choice "$variable" "请选择后台任务操作（回车=$default）: " "$default"
}

show_background_menu() {
    printf '\n%s：\n' "$1"
    printf '  当前状态：%s\n' "${3:-未配置}"
    if [[ "${4:-1}" == 1 ]]; then echo '  1) 启用（默认）'; else echo '  1) 启用'; fi
    if [[ "${2:-0}" == 1 ]]; then
        echo '  2) 停用已有任务'
        if [[ "${4:-1}" == 0 ]]; then echo '  0) 保持现状（默认）'; else echo '  0) 保持现状'; fi
    else
        echo '  2) 不启用（跳过此任务）'
        if [[ "${4:-1}" == 0 ]]; then echo '  0) 不启用（默认）'; fi
    fi
}

background_action_label() {
    case "$1" in
        0) printf '保持现状' ;;
        1) printf '启用' ;;
        2) printf '不启用（已有任务将停用）' ;;
    esac
}

select_scene() {
    step '选择服务器用途 / 线路'
    echo '  网络工具与线路配置：'
    echo '  1) HK / JP 精品线路 — 低延迟线路，NextTrace / sing-box 另选'
    echo '  2) LA 等跨洲线路 — 高延迟、长距离大带宽，工具另选'
    echo '  3) DE / 法兰克福 — 保留 DE 专用 TCP 方案，工具另选'
    echo '  4) 精简基础环境 — 低延迟 TCP 方案，不安装 NextTrace / sing-box'
    echo ''
    echo '  自托管应用：'
    echo '  5) Docker 服务 — 按需选择应用与反向代理（原国内场景）'
    echo '     国内外 VPS 均可选择；是否需要镜像代理取决于服务器网络。'
    echo '  0) 退出脚本'
    if [[ "${VPS_MODE:-full}" == full ]]; then
        echo '  提示：选项 1-4 会配置对应 TCP 参数和 fail2ban；选项 5 部署 Docker 服务。'
    else
        echo '  提示：此处只确定操作范围；当前操作不会重新配置 TCP 参数和系统基础环境。'
    fi
    require_choice VPS_SCENE '请选择用途 / 线路 [0-5，无默认值]: '
    case "$VPS_SCENE" in
        0) exit 0 ;;
        1|hk|jp) VPS_SCENE=hk; SCENE_NAME='HK / JP 精品线路' ;;
        2|la) VPS_SCENE=la; SCENE_NAME='LA 高延迟线路' ;;
        3|de) VPS_SCENE=de; SCENE_NAME='DE / 法兰克福线路' ;;
        4|minimal) VPS_SCENE=minimal; SCENE_NAME='精简基础版' ;;
        5|domestic) VPS_SCENE=domestic; SCENE_NAME='Docker 自托管服务' ;;
        *) die '场景无效：请输入 0-5 或 hk/la/de/minimal/domestic' ;;
    esac
    info "已选择：$SCENE_NAME"
}

select_components() {
    if [[ "${VPS_MODE:-full}" == status ]]; then
        VPS_COMPONENTS=0 INSTALL_NEXTTRACE=0 INSTALL_SING_BOX=0
        return 0
    fi
    if [[ "$VPS_SCENE" == minimal || "$VPS_SCENE" == domestic ]]; then
        [[ "${VPS_COMPONENTS:-0}" == 0 ]] || die '精简版和国内版不支持 VPS_COMPONENTS；境外工具请选择场景 1-3'
        VPS_COMPONENTS=0
    else
        if [[ "${VPS_MODE:-full}" == update ]]; then
            step '选择要更新的工具'
            echo '  只更新已安装工具；尚未安装时请改用“安装 / 调整组件”。'
        else
            step '选择要安装的工具'
        fi
        echo '  NextTrace：查看网络路由与链路；sing-box：代理服务及管理工具。'
        echo '  1) NextTrace + sing-box（默认）'
        echo '  2) 仅 NextTrace'
        echo '  3) 仅 sing-box'
        echo '  0) 不选择'
        require_choice VPS_COMPONENTS '请选择工具 [0-3，回车=1]: ' 1
        case "$VPS_COMPONENTS" in 0|1|2|3) ;; *) die '组件序号必须为 0-3' ;; esac
    fi
    INSTALL_NEXTTRACE=0
    INSTALL_SING_BOX=0
    case "$VPS_COMPONENTS" in
        1) INSTALL_NEXTTRACE=1; INSTALL_SING_BOX=1 ;;
        2) INSTALL_NEXTTRACE=1 ;;
        3) INSTALL_SING_BOX=1 ;;
    esac
}

select_services() {
    AVAILABLE_PROFILES=(tools code media rss files monitoring notes database rustdesk npm)
    declare -gA ENABLED_PROFILES=()
    COMPOSE_PROFILE_ARGS=()
    SELECTED_PROFILE_NAMES=()
    local profile selection item
    local -a requested=()
    step "选择服务组 · $(mode_label "${VPS_MODE:-full}")"
    echo '  仅启动所选服务及其依赖；NPM 可选，PostgreSQL 按应用依赖启动。'
    if [[ "${VPS_MODE:-full}" == status ]]; then
        echo '  请选择要检查的服务组；缺少容器或服务未启动时会报告异常。'
    elif [[ "${VPS_MODE:-full}" == update ]]; then
        echo '  复用已有 Compose 定义；所选服务尚无容器时，会按已有配置创建并启动。'
    else
        echo '  Watchtower 自动更新稍后单独选择；选择服务组会生成 / 更新 Compose 配置。'
    fi
    echo '  1) 导航与工具 — Homepage + IT-Tools'
    echo '  2) 代码托管 — Gitea'
    echo '  3) 音乐与下载 — Navidrome + MeTube'
    echo '  4) RSS 订阅 — RSSHub + Browserless + Redis'
    echo '  5) 文件管理 — File Browser + OpenList'
    echo '  6) 服务监控 — Uptime Kuma + Beszel + Komari'
    echo '  7) 笔记备忘 — Memos'
    echo '  8) 数据库管理 — pgAdmin'
    echo '  9) 远程桌面 — RustDesk（hbbs + hbbr）'
    echo '  10) 反向代理 — NPM（可与其他组组合）'
    echo '  11) 全部可选服务组'
    echo '  0) 仅 NPM 及其数据库（默认，兼容 none）'
    echo '  可多选，例如 1,4,6；0 和 11 需单独使用。未选中的已有服务不会被卸载。'
    require_choice SERVICE_PROFILES '请选择服务组 [回车=0]: ' 0
    selection=${SERVICE_PROFILES//[[:space:]]/}
    case "$selection" in
        11|all) requested=("${AVAILABLE_PROFILES[@]}") ;;
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
            7|notes) profile=notes ;; 8|database) profile=database ;;
            9|rustdesk) profile=rustdesk ;;
            10|npm) profile=npm ;;
            *) die "未知服务选项: $item" ;;
        esac
        ENABLED_PROFILES["$profile"]=1
    done
    for profile in "${AVAILABLE_PROFILES[@]}"; do
        if [[ -n "${ENABLED_PROFILES[$profile]+x}" ]]; then
            SELECTED_PROFILE_NAMES+=("$profile")
        fi
    done
    build_compose_profile_args
}

build_compose_profile_args() {
    local profile
    COMPOSE_PROFILE_ARGS=()
    if [[ ${#SELECTED_PROFILE_NAMES[@]} == 0 ]]; then COMPOSE_PROFILE_ARGS+=(--profile npm); fi
    for profile in "${SELECTED_PROFILE_NAMES[@]}"; do
        COMPOSE_PROFILE_ARGS+=(--profile "$profile")
    done
    if [[ "${WATCHTOWER_ACTION:-0}" == 1 ]]; then
        COMPOSE_PROFILE_ARGS+=(--profile watchtower)
    fi
}

profile_label() {
    case "$1" in
        tools) printf '导航与工具（Homepage、IT-Tools）' ;;
        code) printf '代码托管（Gitea）' ;;
        media) printf '音乐与下载（Navidrome、MeTube）' ;;
        rss) printf 'RSS 订阅（RSSHub、Browserless、Redis）' ;;
        files) printf '文件管理（File Browser、OpenList）' ;;
        monitoring) printf '服务监控（Uptime Kuma、Beszel、Komari）' ;;
        notes) printf '笔记备忘（Memos）' ;;
        database) printf '数据库管理（pgAdmin）' ;;
        rustdesk) printf '远程桌面（RustDesk）' ;;
        npm) printf '反向代理（NPM）' ;;
    esac
}

validate_options() {
    local variable
    for variable in UPGRADE_SYSTEM INSTALL_STARSHIP RESET_STARSHIP_CONFIG; do
        case "${!variable:-0}" in 0|1) ;; *) die "$variable 仅支持 0 或 1" ;; esac
    done
    for variable in IPERF3_ACTION WATCHTOWER_ACTION SB_UPDATE_ACTION; do
        case "${!variable:-0}" in 0|1|2) ;; *) die "$variable 仅支持 0/1/2（保持/启用/停用）" ;; esac
        if [[ "${VPS_MODE:-full}" == status || "${VPS_MODE:-full}" == update ]]; then
            [[ "${!variable:-0}" == 0 ]] || die '检查/更新模式不调整后台策略，请将 ACTION 设为 0，启停请使用组件模式'
        fi
    done
    SERVICE_WAIT_TIMEOUT=${SERVICE_WAIT_TIMEOUT:-300}
    if [[ ! "$SERVICE_WAIT_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || (( SERVICE_WAIT_TIMEOUT > 3600 )); then die 'SERVICE_WAIT_TIMEOUT 必须为 1-3600 秒'; fi
    if [[ "$VPS_SCENE" != domestic ]]; then
        IPERF3_PORT=${IPERF3_PORT:-5201}
        if [[ ! "$IPERF3_PORT" =~ ^[1-9][0-9]{3,4}$ ]] || (( IPERF3_PORT < 1024 || IPERF3_PORT > 65535 )); then die 'IPERF3_PORT 必须是 1024-65535 的整数'; fi
    fi
    STACK_DIR=${STACK_DIR:-/root}
    [[ "$STACK_DIR" == /* && "$STACK_DIR" != / && "$STACK_DIR" != *$'\n'* ]] || die 'STACK_DIR 必须为非根目录的绝对路径'
    # 默认使用原始镜像源；由部署者提供可信的镜像站 JSON 数组。
    DOCKER_MIRRORS=${DOCKER_MIRRORS:-[]}
    if [[ -z "${MEMOS_IMAGE:-}" && -f "$STACK_DIR/docker-compose.yml" ]]; then
        MEMOS_IMAGE=$(awk '/^  memos:/ {inside=1; next} inside && /^    image:/ {print $2; exit}' "$STACK_DIR/docker-compose.yml")
        if [[ "$MEMOS_IMAGE" == neosmemo/memos:latest ]]; then
            if [[ -d "$STACK_DIR/memos/data" ]] && find "$STACK_DIR/memos/data" -type f -print -quit | grep -q .; then
                if [[ "${VPS_MODE:-full}" != status && "${VPS_MODE:-full}" != update && -n "${ENABLED_PROFILES[notes]+x}" ]]; then
                    die '已有旧版 Memos 数据；请先备份并核对升级路径，再显式设置 MEMOS_IMAGE（早于 0.22 需先运行 0.25.3，再升级 0.31.0）'
                fi
            else
                MEMOS_IMAGE=neosmemo/memos:0.31.0
            fi
        fi
    fi
    MEMOS_IMAGE=${MEMOS_IMAGE:-neosmemo/memos:0.31.0}
    [[ "$MEMOS_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9./:@_-]+$ ]] || die 'MEMOS_IMAGE 必须为有效镜像引用，不含空白或 Shell 字符'
}

print_plan() {
    local profile tools=''
    step '本次执行方案'
    info "操作：$(mode_label "${VPS_MODE:-full}")"
    info "用途 / 线路：$SCENE_NAME"
    if [[ "${VPS_MODE:-full}" == full ]]; then
        info '系统配置：主机名（可跳过）、APT 索引更新、基础工具、自动安全更新、日志限制 100M'
        if [[ "${UPGRADE_SYSTEM:-1}" == 1 ]]; then info '系统软件包：执行升级'; else info '系统软件包：跳过升级'; fi
        if [[ "${INSTALL_STARSHIP:-1}" == 1 ]]; then info '终端提示符：配置 Starship'; else info '终端提示符：跳过 Starship'; fi
    elif [[ "$VPS_MODE" == components ]]; then
        info '仅安装所选组件及依赖，不升级系统，不修改主机名、安全策略或 TCP 参数'
    elif [[ "$VPS_MODE" == status ]]; then
        info '只读检查，不安装软件、不修改配置或后台任务'
    elif [[ "$VPS_MODE" == update ]]; then
        info '复用已有配置，仅更新所选的已部署组件 / 服务，不重新初始化系统'
    fi
    if [[ "$VPS_SCENE" == domestic ]]; then
        case "${VPS_MODE:-full}" in
            full|components) info '服务操作：检查 / 安装 Docker 与 Compose，生成配置并启动所选服务' ;;
            status) info '服务操作：读取已有 Compose，检查所选容器运行 / 健康状态' ;;
            update) info '服务操作：读取已有 Compose，拉取所选镜像并重新启动服务' ;;
        esac
        info '服务范围：所选服务及其依赖（NPM 不再附带安装）'
        if [[ ${#SELECTED_PROFILE_NAMES[@]} == 0 ]]; then info '选择 0/none：仅 NPM 及其数据库'; fi
        for profile in "${SELECTED_PROFILE_NAMES[@]}"; do
            printf '  + %s\n' "$(profile_label "$profile")"
        done
        info "Watchtower 自动更新：$(background_action_label "$WATCHTOWER_ACTION")"
        info "服务目录：$STACK_DIR"
    else
        if [[ "${VPS_MODE:-full}" == full ]]; then info "线路配置：应用 $SCENE_NAME 的 TCP 参数，配置 fail2ban"; fi
        [[ "$INSTALL_NEXTTRACE" != 1 ]] || tools='NextTrace'
        [[ "$INSTALL_SING_BOX" != 1 ]] || tools="${tools:+$tools、}sing-box"
        case "${VPS_MODE:-full}" in
            full|components) info "安装工具：${tools:-无}" ;;
            update) info "更新工具：${tools:-无}" ;;
            status) info '检查范围：fail2ban、iperf3、cron、TCP 拥塞控制、sing-box 定时任务' ;;
        esac
        if [[ "${VPS_MODE:-full}" == full || "$VPS_MODE" == components ]]; then
            info "iperf3 测速服务：$(background_action_label "$IPERF3_ACTION")（端口 $IPERF3_PORT）"
            info "sing-box 每日更新：$(background_action_label "$SB_UPDATE_ACTION")"
        fi
    fi
    if [[ "${VPS_MODE:-full}" == full || "$VPS_MODE" == components ]]; then
        info '未选择的组件不会卸载；后台任务选择“停用”会停止对应的已有任务。'
    fi
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
    # 兼容本脚本此前生成的 Compose；追加其他服务组也必须保留已有域名。
    if [[ -z "$HOMEPAGE_HOST" && -f "${STACK_DIR:-/root}/docker-compose.yml" ]]; then
        HOMEPAGE_HOST=$(awk '/^[[:space:]]*- HOMEPAGE_ALLOWED_HOSTS=/ {
            sub(/^[[:space:]]*- HOMEPAGE_ALLOWED_HOSTS=/, ""); print; exit
        }' "${STACK_DIR:-/root}/docker-compose.yml")
    fi
    if [[ -n "${ENABLED_PROFILES[tools]+x}" ]]; then
        require_choice HOMEPAGE_HOST '请输入 Homepage 域名（如 nav.example.com）: '
        is_valid_domain "$HOMEPAGE_HOST" || die 'Homepage 仅允许有效 DNS 域名，不含协议、端口、路径或通配符'
    else
        # 未启用 tools 时不要求私人域名；将来启用前应重新运行并指定域名。
        HOMEPAGE_HOST=${HOMEPAGE_HOST:-nav.example.com}
    fi
    is_valid_domain "$HOMEPAGE_HOST" || die '已有 Homepage 域名无法识别，请通过 HOMEPAGE_HOST 指定有效域名'
}

backup_file() {
    local target=$1 backup
    if [[ -f "$target" ]]; then
        backup=$(mktemp "${target}.bak.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
        cp -a -- "$target" "$backup" || { rm -f -- "$backup"; return 1; }
    fi
}

# 多文件事务：只有内容改变才备份和写入；校验或启动失败时恢复文件及服务原状态。
apply_service_files() {
    local service=$1 validator=$2 enable_service=$3
    shift 3
    local candidate target backup index original_active=0 original_enabled=0 changed=0
    local -a targets=() backups=() candidates=()
    systemctl is-active --quiet "$service" && original_active=1
    systemctl is-enabled --quiet "$service" && original_enabled=1
    # 所有备份成功后才替换任何目标，避免第二份备份失败留下半份配置。
    while (( $# )); do
        candidate=$1 target=$2; shift 2
        if cmp -s -- "$candidate" "$target"; then
            rm -f -- "$candidate"
            continue
        fi
        backup=''
        if [[ -e "$target" ]]; then
            backup=$(mktemp "${target}.bak.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
            cp -a -- "$target" "$backup" || { rm -f -- "$backup"; return 1; }
        fi
        targets+=("$target"); backups+=("$backup"); candidates+=("$candidate")
    done
    for index in "${!targets[@]}"; do
        candidate=${candidates[index]} target=${targets[index]}
        if ! install -m 0644 -- "$candidate" "$target"; then
            rm -f -- "$candidate"
            restore_service_files
            return 1
        fi
        rm -f -- "$candidate"
        changed=1
    done
    if ! "$validator"; then
        error "$service 配置校验失败，恢复本次修改"
        restore_service_files
        return 1
    fi
    if (( changed == 1 || original_active == 0 )); then
        if [[ "$service" == iperf3-server.service ]]; then systemctl daemon-reload || { restore_service_files; return 1; }; fi
        if ! systemctl restart "$service" || ! service_is_ready "$service"; then
            error "$service 启动失败，恢复原配置和运行状态"
            restore_service_state
            return 1
        fi
    else
        info "$service 配置未变化且已运行，跳过备份、写入和重启"
    fi
    if [[ "$enable_service" == 1 ]] && ! systemctl is-enabled --quiet "$service"; then
        if ! systemctl enable "$service"; then
            restore_service_state
            return 1
        fi
    fi
}

restore_service_state() {
    restore_service_files || return 1
    if (( original_active )); then
        if ! systemctl restart "$service" || ! systemctl is-active --quiet "$service"; then
            error "$service 原配置已恢复，但服务恢复失败，请检查 journalctl -u $service"; return 1
        fi
    else
        systemctl stop "$service" || return 1
    fi
    if (( original_enabled == 0 )); then systemctl disable "$service" || return 1; fi
}

# 使用 apply_service_files 的局部数组（Bash 动态作用域），不接触未纳入事务的文件。
restore_service_files() {
    local index failed=0
    for ((index=${#targets[@]}-1; index>=0; index--)); do
        if [[ -n "${backups[index]}" ]]; then
            cp -a -- "${backups[index]}" "${targets[index]}" || failed=1
        else
            rm -f -- "${targets[index]}" || failed=1
        fi
    done
    [[ "$service" != iperf3-server.service ]] || systemctl daemon-reload || failed=1
    (( failed == 0 )) || error '部分配置恢复失败，请使用保留的 .bak 文件人工恢复'
    return "$failed"
}

validate_none() { :; }
validate_fail2ban() { fail2ban-client -t; }
validate_apt() { apt-config dump >/dev/null; }
validate_docker() { dockerd --validate --config-file /etc/docker/daemon.json; }

service_is_ready() {
    local service=$1 pid listeners attempt
    systemctl is-active --quiet "$service" || return 1
    [[ "$service" == iperf3-server.service ]] || return 0
    for attempt in {1..10}; do
        pid=$(systemctl show --property=MainPID --value "$service") || return 1
        listeners=$(ss -H -ltnp "sport = :${IPERF3_PORT}") || return 1
        if [[ "$pid" =~ ^[1-9][0-9]*$ && "$listeners" == *"pid=$pid,"* ]]; then return 0; fi
        sleep 1
    done
    error 'iperf3 未建立属于目标服务的 TCP 监听'
    return 1
}

install_file_if_changed() {
    local candidate=$1 target=$2 mode=${3:-0644}
    if ! cmp -s -- "$candidate" "$target"; then
        backup_file "$target" || return 1
        install -m "$mode" -- "$candidate" "$target" || return 1
    fi
    rm -f -- "$candidate"
}

configure_hostname() {
step "修改主机名"
[[ -n "$NEW_HOSTNAME" ]] || { info "跳过主机名修改"; return 0; }
    HOSTS_NAMES="$NEW_HOSTNAME"
    SHORT_HOSTNAME="${NEW_HOSTNAME%%.*}"
    if [[ "$SHORT_HOSTNAME" != "$NEW_HOSTNAME" ]]; then
        HOSTS_NAMES+=" $SHORT_HOSTNAME"
    fi

    if [[ "$(hostname)" != "$NEW_HOSTNAME" ]]; then
        backup_file /etc/hostname
        hostnamectl set-hostname "$NEW_HOSTNAME"
    fi
    local candidate

    # 防止云镜像的 cloud-init 在重启后恢复云厂商下发的旧主机名。
    if command -v cloud-init &>/dev/null; then
        install -d -m 0755 /etc/cloud/cloud.cfg.d
        candidate=$(mktemp /etc/cloud/cloud.cfg.d/.vps-hostname.XXXXXX)
        printf 'preserve_hostname: true\n' > "$candidate"
        install_file_if_changed "$candidate" /etc/cloud/cloud.cfg.d/99-vps-preserve-hostname.cfg
    fi

    # FQDN 在前、短主机名在后，避免 sudo 报 "unable to resolve host"。
    candidate=$(mktemp /etc/.vps-hosts.XXXXXX)
    awk -v names="$HOSTS_NAMES" '
        $1 == "127.0.1.1" { if (!found++) print "127.0.1.1\t" names; next }
        { print }
        END { if (!found) print "127.0.1.1\t" names }
    ' /etc/hosts > "$candidate"
    install_file_if_changed "$candidate" /etc/hosts
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
apt-get install -y curl wget ca-certificates tar
if [[ "${VPS_MODE:-full}" == full ]]; then apt-get install -y unattended-upgrades; fi
if [[ "$VPS_SCENE" == domestic ]]; then
    apt-get install -y gnupg jq python3
else
    if [[ "${VPS_MODE:-full}" == full ]]; then apt-get install -y fail2ban python3-systemd kmod; fi
    if [[ "${IPERF3_ACTION:-0}" == 1 ]]; then apt-get install -y iperf3 iproute2; fi
    if [[ "${SB_UPDATE_ACTION:-0}" == 1 ]]; then apt-get install -y cron; fi
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
        local module_candidate
        module_candidate=$(mktemp /etc/modules-load.d/.vps-bbr.XXXXXX)
        printf '%s\n' tcp_bbr > "$module_candidate"
        install_file_if_changed "$module_candidate" /etc/modules-load.d/99-vps-bbr.conf
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
    install_file_if_changed "$SYSCTL_FILE" "$SYSCTL_TARGET"
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

local listeners current_pid
listeners=$(ss -H -ltnp "sport = :${IPERF3_PORT}") || return 1
current_pid=$(systemctl show --property=MainPID --value iperf3-server.service 2>/dev/null || true)
if [[ -n "$listeners" ]]; then
    if [[ ! "$current_pid" =~ ^[1-9][0-9]*$ ]] || grep -qv "pid=${current_pid}," <<< "$listeners"; then
        error "端口 $IPERF3_PORT 已被其他进程占用（可能是 iperf3.service），请换用 IPERF3_PORT 或先处理已有服务"
        return 1
    fi
fi

local candidate
candidate=$(mktemp /etc/systemd/system/.iperf3.XXXXXX)
cat > "$candidate" << EOF
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

apply_service_files iperf3-server.service validate_none 1 "$candidate" /etc/systemd/system/iperf3-server.service || return 1
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
        error "NextTrace 安装器失败"
        return 1
    }
    if command -v nexttrace &>/dev/null || command -v nxtrace &>/dev/null; then
        info "NextTrace 安装完成"
    else
        error "NextTrace 未检测到，所选安装未完成"
        return 1
    fi
fi
}

# 233boy 将实际内核放在 /etc/sing-box/bin，PATH 中的 sing-box 通常是管理脚本。
# 不以管理入口是否存在或安装器退出码单独判断成功；不读取或输出节点配置。
probe_singbox_installation() {
    SB_CORE_BIN=''
    SB_CORE_VERSION=''
    SB_INSTALL_STATE=missing
    if [[ -x /etc/sing-box/bin/sing-box ]]; then
        SB_CORE_BIN=/etc/sing-box/bin/sing-box
    else
        SB_CORE_BIN=$(type -P sing-box 2>/dev/null || true)
    fi
    [[ -n "$SB_CORE_BIN" ]] || return 1
    SB_INSTALL_STATE=invalid-core
    # 管理脚本的 version 参数不等同于直接执行内核；残留时也不调用它。
    if [[ "$(readlink -f -- "$SB_CORE_BIN" 2>/dev/null)" == /etc/sing-box/sh/sing-box.sh ]]; then return 1; fi
    if ! SB_CORE_VERSION=$(timeout --kill-after=5s 10 "$SB_CORE_BIN" version 2>/dev/null); then return 1; fi
    [[ "$SB_CORE_VERSION" == 'sing-box version '* ]] || return 1
    SB_CORE_VERSION=${SB_CORE_VERSION%%$'\n'*}
    SB_INSTALL_STATE=inactive
    systemctl is-active --quiet sing-box.service || return 1
    SB_INSTALL_STATE=healthy
}

report_singbox_problem() {
    case "$SB_INSTALL_STATE" in
        missing) error '未检测到可执行的 sing-box 内核，安装未完成' ;;
        invalid-core) error 'sing-box 内核版本检查未通过，或仅留下了管理入口' ;;
        inactive) error 'sing-box 内核可用，但 sing-box.service 未运行，安装未通过服务检查' ;;
    esac
    info '可在服务器上检查：systemctl status sing-box.service --no-pager'
    info '检查配置前请保留现有节点文件；本脚本不会为修复状态而自动重装。'
}

install_singbox() {
    step '安装 sing-box'
    local installer_status=0
    if probe_singbox_installation; then
        info "sing-box 已安装（$SB_CORE_VERSION），服务运行中，跳过安装"
        return 0
    fi
    if [[ "$SB_INSTALL_STATE" != missing || -e /usr/local/bin/sb || -d /etc/sing-box ]]; then
        report_singbox_problem
        return 1
    fi

    if run_installer https://github.com/233boy/sing-box/raw/main/install.sh; then
        installer_status=0
    else
        installer_status=$?
    fi
    if probe_singbox_installation; then
        if (( installer_status != 0 )); then
            warn "安装器退出码为 $installer_status；实际内核和服务检查均已通过，继续初始化"
        fi
        info "sing-box 安装完成（$SB_CORE_VERSION），服务运行中"
        return 0
    fi
    if (( installer_status != 0 )); then
        error "sing-box 安装器退出码为 $installer_status，实际安装检查也未通过"
    fi
    report_singbox_problem
    return 1
}

configure_fail2ban() {
# ---------- 6. 配置 fail2ban ----------
step "配置 fail2ban"

install -d -m 0755 /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d

# 使用最后加载的 .local drop-in，不覆盖用户已有 jail.local；已有 ignoreip 也会保留。
local jail_candidate db_candidate
jail_candidate=$(mktemp /etc/fail2ban/jail.d/.vps-jail.XXXXXX)
db_candidate=$(mktemp /etc/fail2ban/fail2ban.d/.vps-db.XXXXXX)
cat > "$jail_candidate" << 'EOF'
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
cat > "$db_candidate" << 'EOF'
[Definition]
dbpurgeage = 2592000
EOF

apply_service_files fail2ban validate_fail2ban 1 \
    "$jail_candidate" /etc/fail2ban/jail.d/99-vps-sshd.local \
    "$db_candidate" /etc/fail2ban/fail2ban.d/99-vps-local.local || return 1
info "fail2ban 已配置并启动（SSH 递增封禁，最长 7 天）"
}

# 手动更新和定时任务共享锁、超时与更新后的服务验收。
acquire_sb_update_lock() {
    exec 9>/run/lock/sb-auto-update.lock || return 1
    local result=0
    flock -n -E 75 9 || result=$?
    if (( result == 75 )); then return 75; fi
    if (( result != 0 )); then error '无法取得 sing-box 更新锁'; return 1; fi
}

wait_singbox_ready() {
    local attempt consecutive=0
    for ((attempt=0; attempt<15; attempt++)); do
        sleep 2
        if probe_singbox_installation; then
            consecutive=$((consecutive + 1))
            if (( consecutive >= 2 )); then return 0; fi
        else
            consecutive=0
        fi
    done
    error 'sing-box 更新后内核或服务检查失败，请检查 sing-box.service 日志'
    return 1
}

singbox_update_commands() {
    local part caddy_active=0
    [[ -x /usr/local/bin/sb ]] || { error '未找到可执行的 sb 管理脚本'; return 1; }
    for part in sh core; do
        info "更新 sing-box：$part"
        timeout --signal=TERM --kill-after=30s 900 /usr/local/bin/sb update "$part" </dev/null || return 1
    done
    wait_singbox_ready || return 1
    if command -v caddy >/dev/null 2>&1; then
        systemctl is-active --quiet caddy && caddy_active=1
        timeout --signal=TERM --kill-after=30s 900 /usr/local/bin/sb update caddy </dev/null || return 1
        timeout --kill-after=5s 10 caddy version >/dev/null || return 1
        if (( caddy_active )); then systemctl is-active --quiet caddy || return 1; fi
    fi
}

update_singbox() (
    acquire_sb_update_lock || { error '已有 sing-box 更新正在运行，或无法取得锁'; return 1; }
    singbox_update_commands
)

configure_sb_update() {
    step '构建 sing-box 自动更新脚本'
    [[ -x /usr/local/bin/sb ]] || { error '未找到可执行的 sb 管理脚本'; return 1; }
    local candidate
    candidate=$(mktemp /usr/local/bin/.sb-update.XXXXXX) || return 1
    if ! {
        cat <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
info() { printf '[INFO] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
SCRIPT_EOF
        declare -f acquire_sb_update_lock probe_singbox_installation wait_singbox_ready singbox_update_commands
        cat <<'SCRIPT_EOF'
lock_status=0
acquire_sb_update_lock || lock_status=$?
if (( lock_status == 75 )); then info '已有更新任务正在运行，本次跳过'; exit 0; fi
(( lock_status == 0 )) || exit 1
LOG_FILE=/var/log/sb-update.log
if [[ -f "$LOG_FILE" ]]; then
    log_size=$(stat -c '%s' "$LOG_FILE") || exit 1
    if (( log_size >= 5 * 1024 * 1024 )); then mv -f -- "$LOG_FILE" "${LOG_FILE}.1" || exit 1; fi
fi
exec >>"$LOG_FILE" 2>&1
date '+%Y-%m-%d %H:%M:%S 开始更新'
if singbox_update_commands; then
    info '更新完成，sing-box 内核及服务检查通过'
else
    error '更新失败或服务未就绪，请检查日志'
    exit 1
fi
SCRIPT_EOF
    } > "$candidate"; then rm -f -- "$candidate"; return 1; fi
    if ! bash -n "$candidate" || ! install_file_if_changed "$candidate" /usr/local/bin/sb-auto-update.sh 0755; then
        rm -f -- "$candidate"
        return 1
    fi
    if ! systemctl is-active --quiet cron; then systemctl start cron || return 1; fi
    if ! systemctl is-enabled --quiet cron; then systemctl enable cron || return 1; fi
    systemctl is-active --quiet cron || return 1
    set_sb_update_cron 1 || return 1
    info 'sing-box 自动更新脚本已部署（每天 04:00 执行，包含锁、超时和服务验收）'
}


configure_security() {
    step '自动安全更新：保留已有更新来源、重启及清理策略'
    local candidate
    local -a apt_files=()
    # 不覆盖发行版或用户的 20auto-upgrades / 50unattended-upgrades。
    # 仅在没有传统周期配置时维护本脚本的独立 drop-in。
    if [[ ! -e /etc/apt/apt.conf.d/20auto-upgrades ]]; then
        candidate=$(mktemp /etc/apt/apt.conf.d/.vps-auto.XXXXXX)
        cat > "$candidate" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        apt_files+=("$candidate" /etc/apt/apt.conf.d/20vps-auto-upgrades)
    fi
    apply_service_files unattended-upgrades validate_apt 1 "${apt_files[@]}" || return 1
    if (( ${#apt_files[@]} )); then
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer || return 1
    fi
    if systemctl is-active --quiet apt-daily.timer && systemctl is-active --quiet apt-daily-upgrade.timer; then
        info 'APT 调度定时器运行中，自动更新是否启用及更新来源沿用 APT 策略'
    else
        warn 'APT 调度定时器未全部运行，自动安全更新可能不会执行；已保留原调度策略，请检查 apt-daily.timer / apt-daily-upgrade.timer'
    fi

    step 'journald 日志上限 100M'
    install -d -m 0755 /etc/systemd/journald.conf.d
    candidate=$(mktemp /etc/systemd/journald.conf.d/.vps-limit.XXXXXX)
    printf '[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=100M\n' > "$candidate"
    apply_service_files systemd-journald validate_none 0 "$candidate" /etc/systemd/journald.conf.d/limit.conf
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

    apt-get update -o APT::Update::Error-Mode=any
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    info "Docker 安装完成: $(docker --version)"
fi

# 已有 Docker 也独立检查 Compose，任何缺件应在修改 daemon 配置前解决。
ensure_compose_plugin || return 1
command -v dockerd >/dev/null 2>&1 || { error '未找到本机 dockerd；此入口要求本机 rootful Docker Engine'; return 1; }

# 只使用部署者显式提供的镜像站；未提供时保留现有 mirrors。
jq -e 'type == "array" and all(.[]; type == "string" and test("^https?://[^[:space:]]+$"))' <<< "$DOCKER_MIRRORS" >/dev/null || die 'DOCKER_MIRRORS 必须为 HTTP(S) 地址的 JSON 数组'
# 配置 Docker daemon（可选镜像加速 + 日志限制）
mkdir -p /etc/docker
# 将本脚本的配置合并到现有 daemon.json；写入前校验，重启失败则回滚
DAEMON_FILE="/etc/docker/daemon.json"
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

rm -f -- "$DAEMON_FRAGMENT"
apply_service_files docker validate_docker 1 "$DAEMON_CANDIDATE" "$DAEMON_FILE" || return 1
info "Docker daemon 已合并配置（按需设置镜像站 + 全局日志限制）"

# 验证 compose 插件
if docker compose version &>/dev/null; then
    info "Docker Compose 就绪: $(docker compose version --short)"
else
    error "Docker Compose 插件未安装，请检查 Docker 版本"
    exit 1
fi
}

ensure_compose_plugin() {
    if docker compose version >/dev/null 2>&1; then return 0; fi
    local package candidate
    for package in docker-compose-plugin docker-compose-v2; do
        candidate=$(LC_ALL=C apt-cache policy "$package" | awk '/Candidate:/ {print $2; exit}') || return 1
        if [[ -n "$candidate" && "$candidate" != '(none)' ]]; then
            apt-get install -y -o Dpkg::Options::="--force-confold" "$package" || return 1
            docker compose version >/dev/null 2>&1 || { error 'Compose 插件安装后仍不可用'; return 1; }
            return 0
        fi
    done
    error '已有 Docker 缺少 Compose v2+ 插件，当前 APT 源没有可用包；请先配置对应 Docker 仓库。尚未修改 daemon 配置。'
    return 1
}

watchtower_api_version() {
    local version minimum minor
    version=$(docker version --format '{{.Server.APIVersion}}') || return 1
    [[ "$version" =~ ^1\.([0-9]+)$ ]] || { error '无法读取 Docker 服务端 API 版本' >&2; return 1; }
    minor=${BASH_REMATCH[1]}
    # Watchtower 1.7.1 默认 1.25 不被 Docker 29 接受；优先使用兼容的 1.44。
    minimum=$(docker version --format '{{.Server.MinAPIVersion}}') || return 1
    [[ "$minimum" =~ ^1\.([0-9]+)$ ]] || { error '无法读取 Docker 最低 API 版本' >&2; return 1; }
    if (( BASH_REMATCH[1] > 44 )); then error 'Docker 最低 API 已高于 Watchtower 兼容范围，请停用或升级更新器' >&2; return 1; fi
    if (( minor < 25 )); then return 1; fi
    if (( minor > 44 )); then minor=44; fi
    DOCKER_API_VERSION="1.$minor" docker version >/dev/null || return 1
    printf '1.%s\n' "$minor"
}

prepare_filebrowser_storage() {
    [[ -n "${ENABLED_PROFILES[files]+x}" ]] || return 0
    local directory
    for directory in "$STACK_DIR/Filebrowser" "$STACK_DIR/Filebrowser/config" "$STACK_DIR/Filebrowser/database"; do
        [[ ! -L "$directory" ]] || { error "拒绝修改符号链接目录：$directory"; return 1; }
        if [[ ! -d "$directory" ]]; then install -d -m 0750 -o 0 -g 0 "$directory" || return 1; fi
    done
    # FileBrowser 以 root 访问 /root；保留已有配置目录及 /root 的所有权和权限。
}

# Compose 移动目录后仍使用原项目及 Redis 命名卷；结果写入配置供手动管理复用。
resolve_stack_identity() {
    local configuration identity file_project='' file_volume='' containers project='' redis_project='' volume=''
    local -a project_args=()
    local fallback=${STACK_DIR%/}
    fallback=${fallback##*/}
    [[ "${STACK_DIR%/}" != /root ]] || fallback=stacks
    STACK_EXISTING_CONFIG_JSON=''
    containers=$(docker ps --all --format '{{.Names}}') || return 1
    if grep -qx npm <<< "$containers"; then
        project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' npm) || return 1
        [[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { error '已有 npm 容器缺少有效 Compose 项目标签，停止覆盖配置'; return 1; }
    fi
    if grep -qx redis <<< "$containers"; then
        redis_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' redis) || return 1
        [[ "$redis_project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { error '已有 redis 容器缺少有效 Compose 项目标签，停止覆盖配置'; return 1; }
        [[ -z "$project" || "$project" == "$redis_project" ]] || { error '已有 npm 和 redis 属于不同项目，停止覆盖配置'; return 1; }
        project=$redis_project
        volume=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}' redis) || return 1
        [[ -n "$volume" ]] || { error '已有 Redis 的 /data 未使用命名卷，请先核对数据，停止部署'; return 1; }
    fi
    if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
        if [[ -n "$project" ]]; then
            project_args=(--project-name "$project")
        elif [[ -z "${COMPOSE_PROJECT_NAME:-}" && "${STACK_DIR%/}" == /root ]] && ! grep -qE '^name[[:space:]]*:' "$STACK_DIR/docker-compose.yml"; then
            # 旧模板没有 name；即使停服时已删除容器，迁入 /root 后仍沿用旧默认项目 stacks。
            project_args=(--project-name stacks)
        fi
        configuration=$(docker compose "${COMPOSE_ENV_ARGS[@]}" "${project_args[@]}" --profile '*' config --format json) || return 1
        # config 会把字面量 $ 写成 $$，还原后才能复用数据库密码和挂载路径。
        STACK_EXISTING_CONFIG_JSON=${configuration//\$\$/\$}
        identity=$(python3 -c '
import json,sys
config=json.load(sys.stdin)
print(config.get("name", ""))
print(((config.get("volumes") or {}).get("redis-data") or {}).get("name", ""))
' <<< "$configuration") || return 1
        file_project=${identity%%$'\n'*}
        if [[ "$identity" == *$'\n'* ]]; then file_volume=${identity#*$'\n'}; fi
    fi
    STACK_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-${project:-${file_project:-$fallback}}}
    [[ "$STACK_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { error 'Compose 项目名只能使用小写字母、数字、下划线和连字符，且以字母或数字开头'; return 1; }
    [[ -z "$project" || "$STACK_PROJECT_NAME" == "$project" ]] || { error 'COMPOSE_PROJECT_NAME 与已有容器的项目名不同，停止部署'; return 1; }
    if [[ -z "$volume" && "$file_project" == "$STACK_PROJECT_NAME" ]]; then volume=$file_volume; fi
    STACK_REDIS_VOLUME_NAME=${volume:-${STACK_PROJECT_NAME}_redis-data}
    [[ "$STACK_REDIS_VOLUME_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { error '无法识别已有 Redis 命名卷名称，停止部署'; return 1; }
}

# 凭据和每个应用的数据库连接均只在首次生成；不自动迁移已有 SQLite 数据。
prepare_database_storage() {
    VPS_OLD_CONFIG_JSON="${STACK_EXISTING_CONFIG_JSON:-}" python3 - "$STACK_DIR" <<'PY'
import json, os, pathlib, re, secrets, sys
root = pathlib.Path(sys.argv[1])
credential_file = root / ".database.env"
password_keys = ["POSTGRES_PASSWORD", "NPM_DB_PASSWORD", "GITEA_DB_PASSWORD",
                 "MEMOS_DB_PASSWORD", "OPENLIST_DB_PASSWORD", "KOMARI_DB_PASSWORD",
                 "PGADMIN_DEFAULT_PASSWORD", "KOMARI_ADMIN_PASSWORD"]
keys = password_keys + ["PGADMIN_DEFAULT_EMAIL"]
def fail(message):
    sys.exit("数据库配置：" + message)
def check_path(path):
    if path.is_symlink():
        fail("拒绝使用符号链接：" + str(path))
def has_data(path):
    return path.exists() and any(p.is_file() for p in path.rglob("*"))
check_path(credential_file)
if credential_file.exists():
    try:
        lines = credential_file.read_text(encoding="utf-8").splitlines()
        values = dict(line.split("=", 1) for line in lines)
    except (ValueError, UnicodeError):
        fail("凭据文件格式无效；请恢复备份，不要公开其内容")
    if len(lines) != len(keys) or set(values) != set(keys):
        fail("凭据文件项目不完整；请恢复备份，不会重新生成密码")
else:
    if has_data(root / "postgresql" / "data"):
        fail("已有 PostgreSQL 数据但缺少 .database.env，请恢复原凭据文件")
    values = {key: os.environ.get(key) or secrets.token_hex(32) for key in password_keys}
    if not os.environ.get("KOMARI_ADMIN_PASSWORD"):
        values["KOMARI_ADMIN_PASSWORD"] = "K0mari" + secrets.token_hex(32)
    values["PGADMIN_DEFAULT_EMAIL"] = os.environ.get("PGADMIN_DEFAULT_EMAIL") or "admin@example.com"
for key in password_keys:
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,128}", values[key]):
        fail(key + " 必须为 16-128 位字母、数字、下划线或连字符")
if not all(any(test(c) for c in values["KOMARI_ADMIN_PASSWORD"]) for test in (str.isupper, str.islower, str.isdigit)):
    fail("KOMARI_ADMIN_PASSWORD 必须同时包含大小写字母和数字")
if not re.fullmatch(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", values["PGADMIN_DEFAULT_EMAIL"]):
    fail("PGADMIN_DEFAULT_EMAIL 邮箱格式无效")
if not credential_file.exists():
    with open(credential_file, "x", encoding="utf-8", newline="\n", opener=lambda p, flags: os.open(p, flags, 0o600)) as f:
        f.write("".join(key + "=" + values[key] + "\n" for key in keys))
credential_file.chmod(0o600)
services = json.loads(os.environ.get("VPS_OLD_CONFIG_JSON") or "{}").get("services", {})
connections = root / ".database-connections"
check_path(connections)
connections.mkdir(mode=0o700, exist_ok=True)
connections.chmod(0o700)
def postgres(name):
    return "postgres://{0}:{1}@postgresql:5432/{0}?sslmode=disable".format(name, values[name.upper() + "_DB_PASSWORD"])
specs = {
    "npm": ("nginx-proxy-manager", "npm/data", lambda k: k.startswith("DB_"), {
        "DB_POSTGRES_HOST": "postgresql", "DB_POSTGRES_PORT": "5432", "DB_POSTGRES_USER": "npm",
        "DB_POSTGRES_NAME": "npm", "DB_POSTGRES_PASSWORD": values["NPM_DB_PASSWORD"]}),
    "gitea": ("gitea", "gitea/data", lambda k: k.upper().startswith("GITEA__DATABASE__"), {
        "GITEA__database__DB_TYPE": "postgres", "GITEA__database__HOST": "postgresql:5432",
        "GITEA__database__NAME": "gitea", "GITEA__database__USER": "gitea",
        "GITEA__database__PASSWD": values["GITEA_DB_PASSWORD"], "GITEA__database__SSL_MODE": "disable"}),
    "memos": ("memos", "memos/data", lambda k: k in ("MEMOS_DRIVER", "MEMOS_DSN"), {
        "MEMOS_DRIVER": "postgres", "MEMOS_DSN": postgres("memos")}),
    "openlist": ("openlist", "OpenList", lambda k: k.startswith("DB_"), {
        "DB_TYPE": "postgres", "DB_HOST": "postgresql", "DB_PORT": "5432", "DB_USER": "openlist",
        "DB_NAME": "openlist", "DB_PASS": values["OPENLIST_DB_PASSWORD"], "DB_SSL_MODE": "disable"}),
}
for name, (service, directory, is_db_key, defaults) in specs.items():
    target = connections / (name + ".env")
    check_path(target)
    if target.exists():
        target.chmod(0o600)
        continue
    old_env = services.get(service, {}).get("environment") or {}
    env = {k: str(v) for k, v in old_env.items() if is_db_key(k) and v is not None}
    # 旧连接先于目录判断；Gitea/OpenList 保存在 app.ini/config.json 的连接仍由应用读取。
    if not env and not has_data(root / directory):
        env = defaults
    elif not env:
        print(service + "：检测到已有数据，保留原数据库，不自动迁移")
    # Compose env_file 用双引号转义引号/反斜杠，$$ 保留字面量美元符号。
    def quote(value):
        return json.dumps(value.replace("$", "$$"), ensure_ascii=False)
    with open(target, "x", encoding="utf-8", newline="\n", opener=lambda p, flags: os.open(p, flags, 0o600)) as f:
        f.write("".join(k + "=" + quote(v) + "\n" for k, v in env.items()))
PY
}

write_database_initializer() {
    [[ ! -L "$STACK_DIR/postgresql" && ! -L "$STACK_DIR/postgresql/init" && ! -L "$STACK_DIR/postgresql/init/10-apps.sh" ]] || { error 'PostgreSQL 初始化路径不能是符号链接'; return 1; }
    mkdir -p "$STACK_DIR/postgresql/init" || return 1
    cat > "$STACK_DIR/postgresql/init/10-apps.sh" <<'DB_INIT' || return 1
#!/bin/sh
set -eu
# 首次启动由官方入口运行；补装时再次执行，只创建缺失项，不重置账号密码。
for app in npm gitea memos openlist komari; do
    case "$app" in
        npm) DB_PASSWORD=$NPM_DB_PASSWORD ;;
        gitea) DB_PASSWORD=$GITEA_DB_PASSWORD ;;
        memos) DB_PASSWORD=$MEMOS_DB_PASSWORD ;;
        openlist) DB_PASSWORD=$OPENLIST_DB_PASSWORD ;;
        komari) DB_PASSWORD=$KOMARI_DB_PASSWORD ;;
    esac
    export DB_PASSWORD
    psql -X --username "$POSTGRES_USER" --dbname postgres --set=ON_ERROR_STOP=1 --set=app="$app" <<'SQL'
\getenv app_password DB_PASSWORD
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'app', :'app')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'app') \gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'app') \gexec
SQL
done
DB_INIT
    chmod 0644 "$STACK_DIR/postgresql/init/10-apps.sh"
}

# 仅根据已保存连接调整模板依赖，不修改连接或搬迁数据。
adjust_database_dependencies() {
    python3 - "$COMPOSE_CANDIDATE" "$STACK_DIR" <<'PY'
import json, pathlib, re, sys
candidate, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = candidate.read_text(encoding="utf-8")
for app, service, key in (("npm", "nginx-proxy-manager", "DB_POSTGRES_HOST"),
                          ("gitea", "gitea", "GITEA__database__HOST"),
                          ("memos", "memos", "MEMOS_DSN"),
                          ("openlist", "openlist", "DB_HOST")):
    env = {}
    for line in (root / ".database-connections" / (app + ".env")).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"): continue
        k, v = line.split("=", 1)
        env[k.upper()] = json.loads(v) if v.startswith(chr(34)) else v.strip(chr(39))
    host = env.get(key.upper(), "")
    local = "@postgresql:" in host if app == "memos" else host.split(":")[0] == "postgresql"
    if not local:
        pattern = r"(^  " + re.escape(service) + r":\n)(.*?)(?=^  [a-zA-Z0-9_-]+:|^volumes:)"
        text = re.sub(pattern, lambda m: m[1] + m[2].replace("    depends_on:\n      postgresql:\n        condition: service_healthy\n", ""), text, flags=re.M | re.S)
candidate.write_text(text, encoding="utf-8", newline="\n")
PY
}

deploy_services() {
# 只调整默认路径与挂载，不自动搬迁、覆盖旧数据。
if [[ "${STACK_DIR%/}" == /root && ! -f "$STACK_DIR/docker-compose.yml" && -f /opt/stacks/docker-compose.yml ]]; then
    error '检测到 /opt/stacks 的旧部署；请先停服并将 Compose、.browserless.env 和应用数据迁入 /root，音乐迁入 /root/Music，OpenList 数据迁入 /root/OpenList。Redis 保留原命名卷。'
    error '脚本不会自动搬迁旧文件；其他部署目录可通过 STACK_DIR 指定，应用绑定目录均相对它解析，请先核对并迁移数据。'
    return 1
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
ensure_browserless_env "$BROWSERLESS_ENV_FILE" || die 'Browserless 令牌文件不可用，停止部署'
# 防止父进程的同名环境变量覆盖本次部署保存的令牌。
unset BROWSERLESS_TOKEN
COMPOSE_ENV_ARGS=(--env-file "$BROWSERLESS_ENV_FILE" -f "${STACK_DIR}/docker-compose.yml")
if [[ -f "$STACK_DIR/.database.env" ]]; then COMPOSE_ENV_ARGS+=(--env-file "$STACK_DIR/.database.env"); fi
info "Browserless 随机令牌已就绪（保存在服务器上，不输出令牌）"
resolve_stack_identity || return 1
prepare_database_storage || return 1
write_database_initializer || return 1
# 以保存的文件为准，防止父进程同名变量覆盖重跑时使用的密码。
unset POSTGRES_PASSWORD NPM_DB_PASSWORD GITEA_DB_PASSWORD MEMOS_DB_PASSWORD OPENLIST_DB_PASSWORD KOMARI_DB_PASSWORD PGADMIN_DEFAULT_EMAIL PGADMIN_DEFAULT_PASSWORD KOMARI_ADMIN_PASSWORD
COMPOSE_ENV_ARGS=(--env-file "$BROWSERLESS_ENV_FILE" --env-file "$STACK_DIR/.database.env" -f "$STACK_DIR/docker-compose.yml")

COMPOSE_TARGET="${STACK_DIR}/docker-compose.yml"
COMPOSE_CANDIDATE=$(mktemp "${STACK_DIR}/.compose-candidate.XXXXXX")
local watchtower_api=1.44
if [[ "$WATCHTOWER_ACTION" == 1 ]]; then watchtower_api=$(watchtower_api_version) || return 1; fi
cat > "$COMPOSE_CANDIDATE" << 'COMPOSE_EOF'
# 容器日志限制由 /etc/docker/daemon.json 全局配置，无需逐服务设置
name: __STACK_PROJECT_NAME__
x-vps-labels: &vps-labels
  com.centurylinklabs.watchtower.enable: "true"
  com.centurylinklabs.watchtower.scope: "vps-init"
x-vps-healthcheck: &vps-healthcheck
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
services:

  # ==================== 网络与证书管理 ====================
  nginx-proxy-manager:
    profiles: ["npm"]
    labels: *vps-labels
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    env_file: [./.database-connections/npm.env]
    depends_on:
      postgresql:
        condition: service_healthy
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', '/usr/bin/check-health']
  # ==================== 共享数据库与管理 ====================
  postgresql:
    profiles: ["npm", "code", "files", "monitoring", "notes", "database"]
    image: postgres:17-alpine
    container_name: postgresql
    restart: unless-stopped
    # 固定大版本；数据库升级由备份及人工核对控制。
    labels:
      com.centurylinklabs.watchtower.enable: "false"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_DB: postgres
      POSTGRES_PASSWORD: '${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}'
      NPM_DB_PASSWORD: '${NPM_DB_PASSWORD:?NPM_DB_PASSWORD is required}'
      GITEA_DB_PASSWORD: '${GITEA_DB_PASSWORD:?GITEA_DB_PASSWORD is required}'
      MEMOS_DB_PASSWORD: '${MEMOS_DB_PASSWORD:?MEMOS_DB_PASSWORD is required}'
      OPENLIST_DB_PASSWORD: '${OPENLIST_DB_PASSWORD:?OPENLIST_DB_PASSWORD is required}'
      KOMARI_DB_PASSWORD: '${KOMARI_DB_PASSWORD:?KOMARI_DB_PASSWORD is required}'
    volumes:
      - ./postgresql/data:/var/lib/postgresql/data
      - ./postgresql/init:/docker-entrypoint-initdb.d:ro
    # 不发布 5432，应用通过容器网络中的 postgresql:5432 访问。
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD-SHELL', 'pg_isready -h 127.0.0.1 -U "$$POSTGRES_USER" -d postgres']
      start_period: 30s

  pgadmin4:
    labels: *vps-labels
    image: dpage/pgadmin4:latest
    container_name: pgadmin4
    restart: unless-stopped
    profiles: ["database"]
    environment:
      PGADMIN_DEFAULT_EMAIL: '${PGADMIN_DEFAULT_EMAIL:?PGADMIN_DEFAULT_EMAIL is required}'
      PGADMIN_DEFAULT_PASSWORD: '${PGADMIN_DEFAULT_PASSWORD:?PGADMIN_DEFAULT_PASSWORD is required}'
    volumes:
      - pgadmin-data:/var/lib/pgadmin
      - ./pgadmin/servers.json:/pgadmin4/servers.json:ro
    depends_on:
      postgresql:
        condition: service_healthy
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', '/venv/bin/python3', '-c', 'import urllib.request; urllib.request.urlopen("http://127.0.0.1/misc/ping", timeout=5)']
  # ==================== 自动化更新 ====================
  watchtower:
    labels: *vps-labels
    image: containrrr/watchtower:1.7.1
    container_name: watchtower
    profiles: ["watchtower"]
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/localtime:/etc/localtime:ro
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - DOCKER_API_VERSION=__WATCHTOWER_API__
      - WATCHTOWER_LABEL_ENABLE=true
      - WATCHTOWER_SCOPE=vps-init
    # 镜像内置 /watchtower --health-check，只检查更新器进程存活。
    healthcheck:
      <<: *vps-healthcheck
  # ==================== 个人导航与工具 ====================
  homepage:
    labels: *vps-labels
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    profiles: ["tools"]
    volumes:
      - ./homepage:/app/config
    environment:
      - HOMEPAGE_ALLOWED_HOSTS=__HOMEPAGE_HOST__
    # 复用镜像内置的 /api/healthcheck 检查。
    healthcheck:
      <<: *vps-healthcheck

  it-tools:
    labels: *vps-labels
    image: ghcr.io/corentinth/it-tools:latest
    container_name: it-tools
    restart: unless-stopped
    profiles: ["tools"]
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', 'wget', '-q', '--spider', '-T', '5', 'http://127.0.0.1/']

  # ==================== 代码托管 ====================
  gitea:
    labels: *vps-labels
    image: gitea/gitea:latest
    container_name: gitea
    restart: unless-stopped
    profiles: ["code"]
    env_file: [./.database-connections/gitea.env]
    depends_on:
      postgresql:
        condition: service_healthy
    environment:
      - USER_UID=1000
      - USER_GID=1000
    ports:
      - "222:22"
    volumes:
      - ./gitea/data:/data
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', 'curl', '-fsS', '--max-time', '5', '-o', '/dev/null', 'http://127.0.0.1:3000/api/healthz']
      start_period: 120s
  # ==================== 媒体与下载 ====================
  navidrome:
    labels: *vps-labels
    image: deluan/navidrome:latest
    container_name: navidrome
    restart: unless-stopped
    profiles: ["media"]
    volumes:
      - ./navidrome/data:/data
      - ./Music:/music:ro
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', 'curl', '-fsS', '--max-time', '5', '-o', '/dev/null', 'http://127.0.0.1:4533/ping']

  metube:
    labels: *vps-labels
    image: ghcr.io/alexta69/metube
    container_name: metube
    restart: unless-stopped
    profiles: ["media"]
    volumes:
      - ./metube/downloads:/downloads
    # 复用镜像内置检查，兼容其 HTTP(S) 配置。
    healthcheck:
      <<: *vps-healthcheck

  # ==================== RSS 系统 ====================
  rsshub:
    labels: *vps-labels
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
      <<: *vps-healthcheck
      test: ['CMD', 'curl', '-fsS', '--max-time', '5', '-o', '/dev/null', 'http://127.0.0.1:1200/healthz']
    depends_on:
      redis:
        condition: service_healthy
      browserless:
        condition: service_healthy

  browserless:
    labels: *vps-labels
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
    healthcheck:
      <<: *vps-healthcheck
      # $$ 保留给容器 Shell 展开，复用容器的 TOKEN。
      test: ['CMD-SHELL', 'curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:3000/pressure?token=$$TOKEN"']
    ulimits:
      core:
        hard: 0
        soft: 0

  redis:
    labels: *vps-labels
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
    labels: *vps-labels
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
    # 复用镜像内置 /healthcheck.sh，沿用其检查参数。

  openlist:
    labels: *vps-labels
    image: openlistteam/openlist:latest
    container_name: openlist
    profiles: ["files"]
    env_file: [./.database-connections/openlist.env]
    depends_on:
      postgresql:
        condition: service_healthy
    user: "0:0"
    restart: unless-stopped
    volumes:
      - ./OpenList:/opt/openlist/data
    environment:
      - UMASK=022
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD-SHELL', 'test "$$(wget -q -O - -T 5 http://127.0.0.1:5244/ping)" = pong']
  # ==================== 监控系统 ====================
  uptime-kuma:
    labels: *vps-labels
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    restart: unless-stopped
    profiles: ["monitoring"]
    volumes:
      - ./uptime-kuma/data:/app/data
    # 复用镜像内置健康检查及其数据库初始化宽限期。
  beszel:
    labels: *vps-labels
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    profiles: ["monitoring"]
    environment:
      - APP_URL=http://localhost:8090
    volumes:
      - ./beszel/data:/beszel_data
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', '/beszel', 'health', '--url', 'http://localhost:8090']
      interval: 120s
  komari:
    # 监控指标可放 PostgreSQL；账号和站点配置仍保存在 /app/data 的 SQLite 中。
    image: ghcr.io/komari-monitor/komari:1.6.0
    labels:
      com.centurylinklabs.watchtower.enable: "false"
    container_name: komari
    restart: unless-stopped
    profiles: ["monitoring"]
    environment:
      GIN_MODE: release
      KOMARI_LISTEN: 0.0.0.0:25774
    volumes:
      - ./komari/data:/app/data
    depends_on:
      postgresql:
        condition: service_healthy
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', 'curl', '-fsS', '--max-time', '5', '-o', '/dev/null', 'http://127.0.0.1:25774/']
  # ==================== 笔记系统 ====================
  memos:
    image: __MEMOS_IMAGE__
    # 数据库迁移需要备份和人工核对版本路径，不交给 Watchtower 自动升级。
    labels:
      com.centurylinklabs.watchtower.enable: "false"
    container_name: memos
    restart: unless-stopped
    profiles: ["notes"]
    env_file: [./.database-connections/memos.env]
    depends_on:
      postgresql:
        condition: service_healthy
    volumes:
      - ./memos/data:/var/opt/memos
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', 'wget', '-q', '-O', '/dev/null', '-T', '5', 'http://127.0.0.1:5230/healthz']
      start_period: 120s
  # ==================== RustDesk 远程桌面 ====================
  # 官方 classic 镜像基于 scratch，无 shell/健康检查工具；验收仅检查运行状态。
  hbbs:
    labels: *vps-labels
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
    labels: *vps-labels
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
    name: __STACK_REDIS_VOLUME_NAME__
  pgadmin-data:

networks:
  default:
    driver: bridge
COMPOSE_EOF

# 域名已通过严格校验，可安全替换占位符
sed -i "s|__HOMEPAGE_HOST__|${HOMEPAGE_HOST}|g" "$COMPOSE_CANDIDATE"
sed -i "s|__WATCHTOWER_API__|${watchtower_api}|g; s|__MEMOS_IMAGE__|${MEMOS_IMAGE:-neosmemo/memos:0.31.0}|g" "$COMPOSE_CANDIDATE"
sed -i "s|__STACK_PROJECT_NAME__|${STACK_PROJECT_NAME}|g; s|__STACK_REDIS_VOLUME_NAME__|${STACK_REDIS_VOLUME_NAME}|g" "$COMPOSE_CANDIDATE"
mkdir -p "$STACK_DIR/pgadmin" || { rm -f -- "$COMPOSE_CANDIDATE"; return 1; }
if [[ ! -e "$STACK_DIR/pgadmin/servers.json" ]]; then
    printf '%s\n' '{"Servers":{"1":{"Name":"VPS PostgreSQL","Group":"VPS","Host":"postgresql","Port":5432,"MaintenanceDB":"postgres","Username":"postgres","SSLMode":"prefer"}}}' > "$STACK_DIR/pgadmin/servers.json"
fi

adjust_database_dependencies || { rm -f -- "$COMPOSE_CANDIDATE"; return 1; }
if ! docker compose --env-file "$BROWSERLESS_ENV_FILE" --env-file "$STACK_DIR/.database.env" --project-directory "$STACK_DIR" -f "$COMPOSE_CANDIDATE" "${COMPOSE_PROFILE_ARGS[@]}" config -q; then
    rm -f -- "$COMPOSE_CANDIDATE"
    error "docker-compose.yml 校验失败，保留原文件，未拉取镜像或启动服务"
    exit 1
fi
prepare_filebrowser_storage || { rm -f -- "$COMPOSE_CANDIDATE"; return 1; }
local compose_backup='' compose_changed=0
if ! cmp -s -- "$COMPOSE_CANDIDATE" "$COMPOSE_TARGET"; then
    if [[ -f "$COMPOSE_TARGET" ]]; then
        compose_backup=$(mktemp "${COMPOSE_TARGET}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")
        cp -a -- "$COMPOSE_TARGET" "$compose_backup"
    fi
    mv -f -- "$COMPOSE_CANDIDATE" "$COMPOSE_TARGET"
    compose_changed=1
else
    rm -f -- "$COMPOSE_CANDIDATE"
    info 'Compose 内容未变化，跳过备份和替换'
fi
if ! start_selected_services 0; then
    if (( compose_changed )); then
        if [[ -n "$compose_backup" ]]; then
            cp -a -- "$compose_backup" "$COMPOSE_TARGET" || return 1
            error '部署失败，已恢复原 Compose，尝试恢复原服务配置'
            if resolve_selected_services && docker compose "${COMPOSE_ENV_ARGS[@]}" --profile '*' up -d "${SELECTED_SERVICES[@]}" && wait_selected_services; then
                info '原 Compose 对应的服务已恢复并通过启动检查'
            else
                error '原 Compose 已恢复，但服务恢复未通过，请检查容器状态'
            fi
        else
            rm -f -- "$COMPOSE_TARGET"
            error '首次部署失败，已撤回本次 Compose 文件；保留容器供排查'
        fi
    fi
    return 1
fi
info '所选服务已通过启动检查'

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
        warn "如为首次部署，请检查: cd ${STACK_DIR} && docker compose --env-file .browserless.env --env-file .database.env logs filebrowser"
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

echo -e "${CYAN}====== 部署后待办 ======${NC}"
echo ""
print_service_endpoints || return 1
if selected_service postgresql || selected_service pgadmin4 || selected_service komari; then
    info "数据库与管理账号凭据：${STACK_DIR}/.database.env（0600，不输出密码）"
fi

}

read_root_crontab() {
    local errors result=0
    errors=$(mktemp) || return 1
    ROOT_CRONTAB_CONTENT=$(LC_ALL=C crontab -l 2>"$errors") || result=$?
    if (( result != 0 )); then
        if [[ "$result" == 1 && -z "$ROOT_CRONTAB_CONTENT" ]] && grep -qxE 'no crontab for [^[:space:]]+' "$errors"; then
            ROOT_CRONTAB_CONTENT=''
        else
            rm -f -- "$errors"
            error '无法读取现有 crontab，停止修改以保护原有任务'
            return 1
        fi
    fi
    rm -f -- "$errors"
}

backup_root_crontab() {
    local backup
    install -d -m 0700 /var/backups/vps-init || return 1
    backup=$(mktemp /var/backups/vps-init/crontab.XXXXXXXX) || return 1
    printf '%s\n' "$1" > "$backup" || return 1
    info "修改前的 crontab 已保存至 $backup"
}

# 参数 1 输出本脚本的任务，0 输出应保留的其他行；读状态与修改共用规则。
filter_sb_update_cron() {
    awk -v managed_only="$1" '
        {
            managed = (NF >= 6 && $6 == "/usr/local/bin/sb-auto-update.sh") || ($1 ~ /^@/ && $2 == "/usr/local/bin/sb-auto-update.sh")
            if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) managed=0
            if (managed == managed_only) print
        }
    '
}

set_sb_update_cron() {
    local enabled=$1 previous desired
    read_root_crontab || return 1
    previous=$ROOT_CRONTAB_CONTENT
    desired=$(filter_sb_update_cron 0 <<< "$previous") || return 1
    if [[ "$enabled" == 1 ]]; then
        desired="${desired:+$desired$'\n'}0 4 * * * /usr/local/bin/sb-auto-update.sh"
    fi
    if [[ "$desired" != "$previous" ]]; then
        backup_root_crontab "$previous" || return 1
        printf '%s\n' "$desired" | crontab - || return 1
    else
        info 'sing-box 定时任务未变化，跳过写入'
    fi
}

apply_background_actions() {
    if [[ "$VPS_SCENE" != domestic ]]; then
        case "$IPERF3_ACTION" in
            1) configure_iperf3 || return 1 ;;
            2)
                if systemctl cat iperf3-server.service >/dev/null 2>&1; then
                    systemctl disable --now iperf3-server.service || return 1
                fi
                ;;
        esac
        case "$SB_UPDATE_ACTION" in
            1) configure_sb_update || return 1 ;;
            2) if command -v crontab >/dev/null 2>&1; then set_sb_update_cron 0 || return 1; fi ;;
        esac
    fi
}

setup_existing_stack() {
    BROWSERLESS_ENV_FILE="$STACK_DIR/.browserless.env"
    [[ -f "$STACK_DIR/docker-compose.yml" && -f "$BROWSERLESS_ENV_FILE" ]] || { error '未找到已有 Compose 或令牌文件，请先初始化/安装组件'; return 1; }
    if [[ $(wc -l < "$BROWSERLESS_ENV_FILE") -ne 1 ]] || ! grep -qxE 'BROWSERLESS_TOKEN=[0-9a-f]{64}' "$BROWSERLESS_ENV_FILE"; then error '已有令牌文件格式无效'; return 1; fi
    unset BROWSERLESS_TOKEN
    COMPOSE_ENV_ARGS=(--env-file "$BROWSERLESS_ENV_FILE" -f "$STACK_DIR/docker-compose.yml")
    if [[ -f "$STACK_DIR/.database.env" ]]; then
        unset POSTGRES_PASSWORD NPM_DB_PASSWORD GITEA_DB_PASSWORD MEMOS_DB_PASSWORD OPENLIST_DB_PASSWORD KOMARI_DB_PASSWORD PGADMIN_DEFAULT_EMAIL PGADMIN_DEFAULT_PASSWORD KOMARI_ADMIN_PASSWORD
        COMPOSE_ENV_ARGS+=(--env-file "$STACK_DIR/.database.env")
    fi
}

# Compose 的 JSON 输出兼容数组或逐行对象；按 Service 字段逐一核对所选服务。
check_service_snapshot() {
    python3 -c '
import json,sys
text=sys.stdin.read().strip()
decoder=json.JSONDecoder()
rows=[]
try:
    while text:
        item,end=decoder.raw_decode(text)
        rows.extend(item if isinstance(item,list) else [item])
        text=text[end:].lstrip()
    if any(not isinstance(item,dict) for item in rows): raise ValueError()
except (ValueError,TypeError):
    print("无法解析容器状态 JSON",file=sys.stderr)
    sys.exit(2)
failed=False
for service in sys.argv[1:]:
    containers=[row for row in rows if row.get("Service")==service]
    if not containers:
        print(service+": 缺少容器")
        failed=True
    for row in containers:
        state=row.get("State","")
        health=row.get("Health","") or ""
        # RustDesk classic 是 scratch 镜像，没有可执行的健康探针。
        runtime_only=service in ("hbbs","hbbr") and not health
        ready=state=="running" and (health=="healthy" or runtime_only)
        detail="仅检查运行状态，RustDesk 注册/中继需客户端验证" if runtime_only else "缺少健康检查，未通过验收；请用组件模式重新生成配置"
        print(service+": "+state+" / "+(health or detail))
        failed=failed or not ready
sys.exit(1 if failed else 0)
' "$@"
}

wait_selected_services() {
    local timeout=${1:-$SERVICE_WAIT_TIMEOUT} configured snapshot report deadline result
    local -a expected=()
    resolve_selected_services || return 1
    expected=("${SELECTED_SERVICES[@]}")
    deadline=$((SECONDS + timeout))
    while true; do
        snapshot=$(docker compose "${COMPOSE_ENV_ARGS[@]}" --profile '*' ps --all --format json "${SELECTED_SERVICES[@]}") || { error '读取容器状态失败'; return 1; }
        if report=$(check_service_snapshot "${expected[@]}" <<< "$snapshot"); then
            printf '%s\n' "$report"
            return 0
        else
            result=$?
        fi
        if (( result > 1 )); then error '容器状态无法解析或检查工具不可用'; return 1; fi
        if (( SECONDS >= deadline )); then
            printf '%s\n' "$report" >&2
            error '所选服务尚未通过验收（通常需 running + healthy，RustDesk 无探针时仅检查 running），或容器状态无效'
            return 1
        fi
        sleep 2
    done
}

# 显式指定服务名，避免旧 Compose 中未分组的基础容器混入启动/更新。
resolve_selected_services() {
    local configuration resolved
    local -a profiles=("${SELECTED_PROFILE_NAMES[@]}")
    [[ ${#profiles[@]} != 0 ]] || profiles=(npm)
    [[ "${WATCHTOWER_ACTION:-0}" != 1 ]] || profiles+=(watchtower)
    configuration=$(docker compose "${COMPOSE_ENV_ARGS[@]}" --profile '*' config --format json) || return 1
    resolved=$(python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
profiles = set(sys.argv[1:])
# PostgreSQL 只通过真实 depends_on 进入清单，不把共享 profile 当作直接选择。
roots = [name for name, cfg in services.items() if name != "postgresql" and
         (profiles.intersection(cfg.get("profiles", [])) or
          (name == "nginx-proxy-manager" and "npm" in profiles) or
          (name == "watchtower" and "watchtower" in profiles))]
for profile in profiles:
    if not any(profile in services[n].get("profiles", []) or
               (profile, n) in (("npm", "nginx-proxy-manager"), ("watchtower", "watchtower")) for n in roots):
        sys.exit("已有 Compose 缺少所选服务组：" + profile + "；请先使用组件模式生成配置")
seen = set()
def visit(name):
    if name in seen: return
    if name not in services: sys.exit("缺少依赖服务：" + name)
    seen.add(name)
    for dependency in services[name].get("depends_on", {}): visit(dependency)
    print(name)
for name in roots: visit(name)
' "${profiles[@]}" <<< "$configuration") || return 1
    [[ -n "$resolved" ]] || { error '所选服务清单为空，停止操作'; return 1; }
    mapfile -t SELECTED_SERVICES <<< "$resolved"
}

selected_service() {
    local service
    for service in "${SELECTED_SERVICES[@]}"; do [[ "$service" != "$1" ]] || return 0; done
    return 1
}

print_service_endpoints() {
    local configuration snapshot
    configuration=$(docker compose "${COMPOSE_ENV_ARGS[@]}" --profile '*' config --format json) || return 1
    snapshot=$(docker compose "${COMPOSE_ENV_ARGS[@]}" --profile '*' ps --all --format json "${SELECTED_SERVICES[@]}") || return 1
    VPS_SERVICE_SNAPSHOT="$snapshot" python3 -c '
import json, os, sys
services = json.load(sys.stdin)["services"]
text = os.environ["VPS_SERVICE_SNAPSHOT"].strip()
try: rows = json.loads(text or "[]")
except json.JSONDecodeError: rows = [json.loads(line) for line in text.splitlines() if line.strip()]
if isinstance(rows, dict): rows = [rows]
running = {r.get("Service") for r in rows if r.get("State") == "running"}
ports = {"homepage":3000,"it-tools":80,"gitea":3000,"navidrome":4533,"metube":8081,
         "rsshub":1200,"browserless":3000,"redis":6379,"filebrowser":80,"openlist":5244,
         "uptime-kuma":3001,"beszel":8090,"komari":25774,"memos":5230,"pgadmin4":80,"postgresql":5432}
print("本次所选且正在运行的服务访问说明：")
for name in sys.argv[1:]:
    if name not in running: continue
    cfg = services[name]
    print("  " + name)
    if name == "hbbs":
        print("    主机网络：TCP 21115、21116，UDP 21116；Web 客户端另需 TCP 21118")
        print("    ID 服务器填 VPS IP/域名；Key 见 rustdesk/data/id_ed25519.pub")
    elif name == "hbbr":
        print("    主机网络：TCP 21117；Web 客户端另需 TCP 21119")
    elif cfg.get("ports"):
        for p in cfg["ports"]:
            print("    宿主机 {}:{} → 容器 {}/{}".format(p.get("host_ip", "0.0.0.0"), p.get("published", "动态分配"), p["target"], p.get("protocol", "tcp")))
        if name == "nginx-proxy-manager": print("    管理界面使用上述映射到容器 81 的端口；首次凭据请查镜像说明")
    elif name in ports:
        print("    容器内网 {}:{}（未发布宿主机端口；Web 服务需另行配置反代或端口映射）".format(name, ports[name]))
    else: print("    无对外访问端口")
' "${SELECTED_SERVICES[@]}" <<< "$configuration"
}

prepare_postgresql_databases() {
    selected_service postgresql || return 0
    # 兼容仍在使用旧 Compose 的状态/更新模式。
    grep -q '^  postgresql:' "$STACK_DIR/docker-compose.yml" || return 0
    [[ -f "$STACK_DIR/.database.env" && -f "$STACK_DIR/postgresql/init/10-apps.sh" ]] || { error '缺少数据库凭据或初始化文件，请先恢复备份或使用组件模式'; return 1; }
    docker compose "${COMPOSE_ENV_ARGS[@]}" up -d postgresql || return 1
    local deadline=$((SECONDS + SERVICE_WAIT_TIMEOUT))
    until docker compose "${COMPOSE_ENV_ARGS[@]}" exec -T postgresql pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; do
        (( SECONDS < deadline )) || { error 'PostgreSQL 启动超时，未启动应用'; return 1; }
        sleep 2
    done
    docker compose "${COMPOSE_ENV_ARGS[@]}" exec -T postgresql sh /docker-entrypoint-initdb.d/10-apps.sh || { error '应用数据库创建失败，未启动应用'; return 1; }
}

initialize_komari() {
    [[ -n "${ENABLED_PROFILES[monitoring]+x}" && -f "$STACK_DIR/.database.env" ]] || return 0
    grep -q '^  komari:' "$STACK_DIR/docker-compose.yml" || return 0
    local response code required deadline=$((SECONDS + SERVICE_WAIT_TIMEOUT))
    while true; do
        response=$(docker compose "${COMPOSE_ENV_ARGS[@]}" exec -T komari curl -sS --max-time 5 -w '\n%{http_code}' http://127.0.0.1:25774/api/install/status 2>/dev/null) || response=''
        code=${response##*$'\n'}
        # 安装 API 在已完成安装后返回 404；保留原指标库及账号，不重置已有实例。
        [[ "$code" != 404 ]] || return 0
        if [[ "$code" == 200 ]]; then
            required=$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["data"]["required"]).lower())' <<< "${response%$'\n'*}") || return 1
            [[ "$required" == true ]] || return 0
            break
        fi
        (( SECONDS < deadline )) || { error 'Komari 安装接口启动超时'; return 1; }
        sleep 2
    done
    # 使用官方首次安装接口，只向新实例提交一次；凭据从受限文件读入标准输入。
    python3 - "$STACK_DIR/.database.env" <<'PY' | docker compose "${COMPOSE_ENV_ARGS[@]}" exec -T komari curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:25774/api/install/complete >/dev/null
import json, pathlib, sys
values = dict(line.split("=", 1) for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines())
print(json.dumps({"username": "admin", "password": values["KOMARI_ADMIN_PASSWORD"], "sitename": "Komari",
                  "metric_dsn": "postgresql://komari:" + values["KOMARI_DB_PASSWORD"] + "@postgresql:5432/komari?sslmode=disable"}))
PY
}

start_selected_services() {
    resolve_selected_services || return 1
    local update=$1
    if [[ "$update" == 1 ]]; then
        docker compose "${COMPOSE_ENV_ARGS[@]}" --profile '*' pull "${SELECTED_SERVICES[@]}" || { error '镜像更新失败，未执行启动'; return 1; }
    fi
    prepare_postgresql_databases || return 1
    # 普通安装只补齐缺失镜像；不主动替换已有镜像。
    docker compose "${COMPOSE_ENV_ARGS[@]}" --profile '*' up -d "${SELECTED_SERVICES[@]}" || { error 'Compose 启动失败'; return 1; }
    initialize_komari || { error 'Komari 首次配置失败，请检查服务日志后重跑'; return 1; }
    if [[ "$WATCHTOWER_ACTION" == 2 ]]; then
        docker compose "${COMPOSE_ENV_ARGS[@]}" --profile watchtower stop watchtower || return 1
    fi
    wait_selected_services || return 1
}

show_status() {
    if [[ "$VPS_SCENE" == domestic ]]; then
        setup_existing_stack || return 1
        wait_selected_services 0
    else
        local service state
        for service in fail2ban iperf3-server.service cron; do
            state=$(systemctl is-active "$service" 2>/dev/null || true)
            info "$service: ${state:-未安装}"
        done
        info "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '由宿主机管理')"
        if command -v crontab >/dev/null 2>&1; then
            read_root_crontab || return 1
            if [[ -n "$(filter_sb_update_cron 1 <<< "$ROOT_CRONTAB_CONTENT")" ]]; then info 'sing-box 定时更新：已配置'; else info 'sing-box 定时更新：未配置'; fi
        fi
    fi
}

update_selected() {
    if [[ "$VPS_SCENE" == domestic ]]; then
        setup_existing_stack || return 1
        start_selected_services 1
    else
        if [[ "$INSTALL_NEXTTRACE" == 1 ]]; then
            if ! command -v nexttrace >/dev/null 2>&1 && ! command -v nxtrace >/dev/null 2>&1; then error 'NextTrace 未安装，请使用组件安装模式'; return 1; fi
            run_installer https://nxtrace.org/nt || return 1
        fi
        if [[ "$INSTALL_SING_BOX" == 1 ]]; then
            [[ -x /usr/local/bin/sb ]] || { error '未找到 sb 管理脚本，请先安装'; return 1; }
            update_singbox || return 1
        fi
    fi
}

# 第三方安装程序先完整下载并检查 Bash 语法，下载失败不得执行部分内容。
run_installer() (
    local installer tty_fd
    installer=$(mktemp)
    trap 'rm -f -- "$installer"' EXIT
    curl -fsSL --connect-timeout 15 --max-time 120 "$1" -o "$installer" || return 1
    [[ -s "$installer" ]] && bash -n "$installer" || return 1
    if { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
        bash "$installer" <&"$tty_fd"
    else
        bash "$installer" </dev/null
    fi
)

show_help() {
    cat <<'HELP'
用法：bash vps-init.sh [--plan | --help]
  --plan  显示本机概况、选择并打印方案，不安装软件或修改系统；可在普通用户下执行。
  --help  显示帮助。
启动顺序：本机系统概况 → 选择操作 → 选择用途 / 线路 → 选择工具 / 服务组 → 后台任务 → 执行方案。
系统概况只读取本机信息，不联网探测；正式执行前校验系统版本、root 权限及 systemd。
操作（VPS_MODE，保留原编号）：
  1) full：完整初始化，适合新机器（回车默认选择）
  2) components：安装 / 调整组件，适合补装工具、部署服务、调整后台任务
  3) status：查看运行状态（只读）
  4) update：更新已有组件 / 服务，复用当前配置
  0) 退出
场景（VPS_SCENE）：
  1) hk / jp：HK / JP 精品线路
  2) la：LA 高延迟线路
  3) de：DE / 法兰克福线路
  4) minimal：精简基础版
  5) domestic：Docker 自托管服务（原国内场景，国内外 VPS 均可选）
  0) 退出
只有完整初始化才应用场景中的系统 / TCP 配置；其他操作仅以场景确定组件范围。
境外组件（VPS_COMPONENTS）：
  1) NextTrace + sing-box（直接回车默认选择）
  2) 仅 NextTrace
  3) 仅 sing-box
  0) 不选择
后台选项（IPERF3_ACTION / WATCHTOWER_ACTION / SB_UPDATE_ACTION）：
  1) 启用（iperf3 / sing-box 安装模式默认选择）
  2) 新任务不启用；已有任务停用
  0) 保持现状（已有任务时显示，也接受显式环境变量）
Watchtower 默认选择 0，新装不启用；iperf3 / sing-box 新装只显示前两项。
检查/更新模式不显示后台菜单，ACTION 默认保持为 0。
Docker 服务组（SERVICE_PROFILES，支持逗号多选，也接受对应 profile 名称）：
  1) tools：导航与工具（Homepage + IT-Tools）
  2) code：代码托管（Gitea）
  3) media：音乐与下载（Navidrome + MeTube）
  4) rss：RSS 订阅（RSSHub + Browserless + Redis）
  5) files：文件管理（File Browser + OpenList）
  6) monitoring：服务监控（Uptime Kuma + Beszel + Komari）
  7) notes：笔记备忘（Memos）
  8) database：数据库管理（pgAdmin）
  9) rustdesk：远程桌面（hbbs + hbbr，共享 rustdesk/data，使用主机网络）
  10) npm：可选 NPM 反向代理，可与其他组组合
  11) all：全部服务组
  0) none：仅 NPM 及其数据库（默认）
例如 1,4,6；0 和 11 需单独使用。后台任务单独选择，未选择的已有服务不会被卸载。
其他变量：VPS_HOSTNAME、UPGRADE_SYSTEM、INSTALL_STARSHIP、RESET_STARSHIP_CONFIG、
          IPERF3_PORT、HOMEPAGE_HOST、MEMOS_IMAGE、STACK_DIR、COMPOSE_PROJECT_NAME、DOCKER_MIRRORS、SERVICE_WAIT_TIMEOUT。
数据库：PGADMIN_DEFAULT_EMAIL（默认 admin@example.com）；首次可通过 POSTGRES_PASSWORD、
        NPM_DB_PASSWORD、GITEA_DB_PASSWORD、MEMOS_DB_PASSWORD、OPENLIST_DB_PASSWORD、KOMARI_DB_PASSWORD、
        PGADMIN_DEFAULT_PASSWORD、KOMARI_ADMIN_PASSWORD 提供密码，否则随机生成；限 16-128 位字母数字及 _-。
Komari 初始用户名 admin，密码须同时有大小写字母和数字。凭据保存为 .database.env（0600），重跑以文件为准。
新部署 NPM/Gitea/Memos/OpenList 及 Komari 指标库使用 PostgreSQL，各自独立库和账号；已有数据库连接/数据保留。
手动 Compose：docker compose --env-file .browserless.env --env-file .database.env <子命令>。
Docker 默认目录：/root；Compose 为 /root/docker-compose.yml，应用数据均位于该目录下。
File Browser 固定管理 /root；Redis 保留命名卷。已有部署沿用原项目名和实际 Redis 卷名。
所选服务需达到 running + healthy；RustDesk classic 无健康探针，仅检查 running，需另用客户端验证。
RustDesk 需放行 TCP 21115–21117、UDP 21116；客户端 Key 使用 rustdesk/data/id_ed25519.pub。
应用新挂载及健康检查请选组件模式。
旧部署需先停服、备份并迁移 Compose、令牌、.database.env、.database-connections 与应用数据；脚本不会自动搬迁文件。
旧自定义项目在容器已删除后迁移时，请通过 COMPOSE_PROJECT_NAME 指定原项目名。
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
    print_system_overview
    if (( plan_only == 1 )); then
        info '当前为方案预览：只读取本机信息和打印选择，不安装软件或修改系统。'
    fi
    select_mode
    select_scene
    select_components
    if [[ "$VPS_SCENE" == domestic ]]; then select_services; fi
    select_background_actions
    if [[ "$VPS_SCENE" == domestic ]]; then build_compose_profile_args; fi
    validate_options
    print_plan
    (( plan_only == 0 )) || return 0
    preflight
    if [[ "$VPS_MODE" == status ]]; then show_status; return $?; fi
    if [[ "$VPS_MODE" == update ]]; then update_selected; return $?; fi
    if [[ "$VPS_MODE" == full ]]; then collect_hostname; fi
    if [[ "$VPS_SCENE" == domestic ]]; then collect_homepage; fi
    if [[ "$VPS_MODE" == full ]]; then
        configure_hostname
    else
        UPGRADE_SYSTEM=0
    fi
    if [[ "$VPS_MODE" == full || "$VPS_SCENE" == domestic || "$INSTALL_NEXTTRACE" == 1 || "$INSTALL_SING_BOX" == 1 || "$IPERF3_ACTION" == 1 || "$SB_UPDATE_ACTION" == 1 ]]; then
        install_base
    else
        info '没有需要安装的组件，仅处理所选后台任务，跳过 APT'
    fi
    if [[ "$VPS_MODE" == full ]]; then
        step '终端美化：Starship（Bash）'
        configure_starship
        configure_security
    fi
    if [[ "$VPS_SCENE" == domestic ]]; then
        install_docker
        deploy_services
    else
        if [[ "$VPS_MODE" == full ]]; then
            configure_tcp
            configure_fail2ban
        fi
        if [[ "$INSTALL_NEXTTRACE" == 1 ]]; then install_nexttrace; fi
        if [[ "$INSTALL_SING_BOX" == 1 ]]; then install_singbox; fi
        apply_background_actions
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
