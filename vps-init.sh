#!/bin/bash
# ============================================================
# VPS һ����ʼ���ű���������ڣ����ļ��������У�
# ����ϵͳ��Debian 11+ / Ubuntu 22.04+
# �����ѡ����·����������������ִ��һ�Ρ�ԭ�����汾������Ǩ�ƺ˶ԡ�
# ============================================================

set -euo pipefail

# ---------- ��ɫ���� ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}======== $1 ========${NC}"; }

# ---------- Starship �������ã����汾����һ�£� ----------
# ʹ���� Shell ������ʱ�ļ������ı����ű�������ߵ� Shell��
configure_starship() (
    case "${INSTALL_STARSHIP:-1}" in
        0) info "��ͨ�� INSTALL_STARSHIP=0 ���� Starship"; return 0 ;;
        1) ;;
        *) error "INSTALL_STARSHIP ��֧�� 0 �� 1"; return 1 ;;
    esac

    case "${RESET_STARSHIP_CONFIG:-0}" in
        0|1) ;;
        *) error "RESET_STARSHIP_CONFIG ��֧�� 0 �� 1"; return 1 ;;
    esac

    local account_home work_dir installer login_file file staged backup_id i
    local theme_preserved=false
    local -a targets staged_files
    account_home=$(getent passwd "$EUID" | cut -d: -f6)
    if [[ "$account_home" != /* || ! -d "$account_home" ]]; then
        error "�޷�ȷ����ǰ root �˺ŵ���Ŀ¼��ֹͣ���� Starship"
        return 1
    fi
    work_dir=$(mktemp -d)
    trap 'rm -rf -- "$work_dir"' EXIT
    installer="$work_dir/install.sh"

    if command -v starship >/dev/null 2>&1; then
        info "Starship �Ѱ�װ�����������а汾"
    else
        info "�� Starship �ٷ�վ�����ذ�װ����..."
        # ������������ִ�У�����ʧ��ʱ��ִ�в�ȱ�ű���
        if ! curl -fsSL --connect-timeout 15 --max-time 120 \
            https://starship.rs/install.sh -o "$installer"; then
            warn "Starship ��װ��������ʧ�ܣ������ն�������������ʼ������"
            return 0
        fi
        install -d -m 0755 /usr/local/bin
        if ! sh "$installer" --yes --bin-dir /usr/local/bin; then
            warn "Starship ��װʧ�ܣ������ն�������������ʼ������"
            return 0
        fi
        hash -r
    fi
    if ! starship --version; then
        warn "Starship �޷����У��������� Shell ���ã�������ʼ������"
        return 0
    fi

    cat > "$work_dir/starship.toml" << 'STARSHIP_CONFIG_EOF'
# VPS ��൥����ʾ�������� Nerd Font��
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

    # .bash_profile / .bash_login ����ʱ��Bash ��¼��һ����ȡ .profile��
    # ͬʱ���� .bashrc ��ʵ����Ч�ĵ�¼�ļ���ͬһ�� Shell ֻ��ʼ��һ�Ρ�
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
            # ֻ�滻���ű����������飬�����û����������á�
            if ! awk '
                $0 == "# >>> vps-init starship >>>" { if (inside) exit 1; inside=1; next }
                $0 == "# <<< vps-init starship <<<" { if (!inside) exit 1; inside=0; next }
                !inside { print }
                END { if (inside) exit 1 }
            ' "$file" > "$staged"; then
                error "$file �� Starship ��ǲ�������δ�޸�ԭ�ļ�"
                return 1
            fi
        fi
        cat >> "$staged" << 'STARSHIP_INIT_EOF'
# >>> vps-init starship >>>
# ���ڽ���ʽ Bash �м��أ��������� Shell ���� Bash ��ʼ�����롣
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
            error "$file �� Bash �﷨У��ʧ�ܣ�δ�޸�ԭ�ļ�"
            return 1
        fi
    done

    mkdir -p "$account_home/.config"
    backup_id="$(date +%Y%m%d-%H%M%S).${work_dir##*.}"
    # ȫ��׼����У�����д�룻�����ݱ仯ʱ�ű��ݺ��滻��
    for i in 0 1 2; do
        file=${targets[$i]}
        staged=${staged_files[$i]}
        # Ĭ�ϱ����������⣻ֻ����ȷҪ������ʱ��Ӧ�����õ�����ʽ��
        if [[ "$i" == 0 && "${RESET_STARSHIP_CONFIG:-0}" == 0 ]] && \
            [[ -e "$file" || -L "$file" ]]; then
            theme_preserved=true
            info "�ѱ������� Starship ����: $file��RESET_STARSHIP_CONFIG=1 �����ã�"
            continue
        fi
        if cmp -s "$staged" "$file"; then
            continue
        fi
        if [[ -e "$file" ]]; then
            cp -pL -- "$file" "$file.bak.$backup_id"
            info "�ѱ���: $file.bak.$backup_id"
        fi
        cp -- "$staged" "$file"
    done
    if [[ "$theme_preserved" == true ]]; then
        info "Starship Bash �Զ����������ã�����ʹ����������"
    else
        info "Starship �����ã���ɫ������ʾ����> ��Ŀ¼ͬһ�У����޶������"
    fi
    info "�������� SSH�����ڵ�ǰ Bash ִ��: source ~/.bashrc"
    info "�����õ�ǰ root �˺ţ������л���¼ Shell ��ж�� fish"
)
# ---------- Starship �������ý��� ----------

# ʼ�մӿ����ն˶�ȡ�������룬���� curl | bash ʱ����ű��ܵ���
# -e ���� Readline��֧���˸�Delete �ͷ�����༭��
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
        warn "δ��⵽�ɽ����նˣ���ʹ��Ĭ��ֵ"
    fi

    # read �ɹ���������ʱҲӦ��Ĭ��ֵ���������ȿ�Ĭ��ֵ�Ա���Ϊ�ա�
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


# ---------- ϵͳ�ſ������ѡ�񣨲��޸�ϵͳ�� ----------
die() { error "$1" >&2; exit 1; }

# ���� Shell �ж�ȡϵͳ��Ϣ������ os-release �ı���Ӱ���������
# ����̽���Ϊ����ֻ������������ϵͳȱ������� /proc �ֶ�ʱ��ʾ��δ֪����
print_system_overview() (
    local os_name kernel arch host cpu_count cpu_model memory swap disk uptime_text load virt init_state user_name
    step 'Linux ϵͳ�ſ�'
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
            END {if (total>0) {printf "�ܼ� %.0f MiB", total/1024; if (found) printf " / ���� %.0f MiB", available/1024}}' /proc/meminfo 2>/dev/null || true)
        swap=$(awk '/^SwapTotal:/ {total=$2; found=1} /^SwapFree:/ {free=$2}
            END {if (found) {if (total==0) printf "δ����"; else printf "�ܼ� %.0f MiB / ���� %.0f MiB", total/1024, free/1024}}' /proc/meminfo 2>/dev/null || true)
    fi
    disk=$(LC_ALL=C df -Pk / 2>/dev/null | awk 'NR==2 {printf "�ܼ� %.1f GiB / ���� %.1f GiB / ���� %s", $2/1048576, $4/1048576, $5}' || true)
    if [[ -r /proc/uptime ]]; then
        uptime_text=$(awk '{printf "%d �� %d Сʱ %d ����", $1/86400, ($1%86400)/3600, ($1%3600)/60}' /proc/uptime 2>/dev/null || true)
    fi
    if [[ -r /proc/loadavg ]]; then
        load=$(awk '{printf "%s / %s / %s��1 / 5 / 15 ���ӣ�", $1, $2, $3}' /proc/loadavg 2>/dev/null || true)
    fi
    virt=$(systemd-detect-virt 2>/dev/null || true)
    [[ "$virt" != none ]] || virt='δ��⵽���⻯'
    init_state='δ��⵽�����е� systemd'
    [[ ! -d /run/systemd/system ]] || init_state='systemd ������'
    user_name=$(id -un 2>/dev/null || true)
    printf '  �������ƣ�%s\n' "${host:-δ֪}"
    printf '  ����ϵͳ��%s\n' "${os_name:-δ֪}"
    printf '  �ں˼ܹ���%s / %s\n' "${kernel:-δ֪}" "${arch:-δ֪}"
    printf '  CPU��%s �߼���%s\n' "${cpu_count:-δ֪}" "${cpu_model:+ / $cpu_model}"
    printf '  �ڴ棺%s\n  Swap��%s\n' "${memory:-δ֪}" "${swap:-δ֪}"
    printf '  ��������%s\n' "${disk:-δ֪}"
    printf '  ����ʱ����%s\n  ϵͳ���أ�%s\n' "${uptime_text:-δ֪}" "${load:-δ֪}"
    printf '  ���⻯��%s\n  ���������%s\n' "${virt:-δ֪}" "$init_state"
    printf '  ��ǰ�û���%s��UID=%s��\n' "${user_name:-δ֪}" "$EUID"
    info '����Ҫ��Debian 11+ / Ubuntu 22.04+��root Ȩ�ޡ������е� systemd����ʽִ��ǰ��У�顣'
)

mode_label() {
    case "$1" in
        full) printf '������ʼ��' ;;
        components) printf '��װ / �������' ;;
        status) printf '�鿴����״̬��ֻ����' ;;
        update) printf '����������� / ����' ;;
    esac
}

require_choice() {
    local variable=$1 prompt=$2 fallback=${3-}
    if [[ -z "${!variable:-}" ]]; then
        read_tty "$variable" "$prompt" "$fallback"
        [[ -n "${!variable}" ]] || die "ȱ�� $variable�����ڽ����ն�ѡ���ͨ�����������ṩ"
    fi
}

select_mode() {
    step 'ѡ�����'
    echo '  1) ������ʼ����Ĭ�ϣ�'
    echo '     �ʺ��»���������ϵͳ�����������ٰ�װ��ѡ���߻����'
    echo '  2) ��װ / �������'
    echo '     �ʺ����л�������װ���ߡ���������飬�������̨����'
    echo '     ����ȫϵͳ������������������TCP ������ϵͳ��ȫ���ԡ�'
    echo '  3) �鿴����״̬��ֻ����'
    echo '     �����ѡ��Χ�����з��񣬲���װ���޸����á�'
    echo '  4) ����������� / ����'
    echo '     �����Ѱ�װ���߻���ȡ�����������������á�'
    echo '  0) �˳��ű�'
    require_choice VPS_MODE '��ѡ����� [0-4���س�=1]: ' 1
    case "$VPS_MODE" in
        0) exit 0 ;;
        1|full) VPS_MODE=full ;;
        2|components) VPS_MODE=components ;;
        3|status) VPS_MODE=status ;;
        4|update) VPS_MODE=update ;;
        *) die 'ģʽ��Ч�������� 0-4 �� full/components/status/update' ;;
    esac
    info "��ѡ��$(mode_label "$VPS_MODE")"
}

# ��װģʽĬ���������õĺ�̨�������������չʾ��������״����
# ACTION=0 �Խ�����ʽ�������������ݾ��Զ��������/����ģʽʼ�ղ�������̨����

select_background_actions() {
    if [[ "$VPS_MODE" == full || "$VPS_MODE" == components ]]; then
        step '���ú�̨����'
        echo '  �����������ѡ�����ú��������л򰴼ƻ�ִ�С�'
        if [[ "$VPS_SCENE" == domestic ]]; then
            echo '  Watchtower����ʱ���±��ű�������������Memos �������Զ����¡�'
            choose_background_action WATCHTOWER_ACTION 'Watchtower �Զ�����'
        else
            printf '  iperf3������������ٷ��񣬶˿� %s���ͻ������iperf3 -c ��������ַ -p %s��\n' "${IPERF3_PORT:-5201}" "${IPERF3_PORT:-5201}"
            echo '  �˷�����������֤���������� IP ���ж˿ڡ�'
            choose_background_action IPERF3_ACTION 'iperf3 ��פ����'
            if sb_update_supported; then
                echo '  sing-box��ÿ�� 04:00��������ʱ�������¹����ű����ںˡ�'
                choose_background_action SB_UPDATE_ACTION 'sing-box ��ʱ����'
            else
                [[ "${SB_UPDATE_ACTION:-0}" != 1 ]] || die '���ö�ʱ������Ҫ���� sb �����ű����򱾴�ѡ����װ sing-box'
                info '����δѡ����װ sing-box���������ں�ȱ�� sb ������ڣ�������ʱ����ѡ��'
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
    # ԭ���ں��Ѱ�װ�����С���û�� 233boy �������ʱ�������ò����õ� sb ��ʱ����
    if probe_singbox_installation; then return 1; fi
    return 0
}

probe_background_state() {
    BACKGROUND_PRESENT=0
    BACKGROUND_STATE='δ����'
    local current enabled cron_content
    case "$1" in
        IPERF3_ACTION)
            if systemctl cat iperf3-server.service >/dev/null 2>&1; then
                BACKGROUND_PRESENT=1
                current=$(systemctl is-active iperf3-server.service 2>/dev/null || true)
                enabled=$(systemctl is-enabled iperf3-server.service 2>/dev/null || true)
                if [[ "$current" == active ]]; then BACKGROUND_STATE='������'; else BACKGROUND_STATE='δ����'; fi
                if [[ "$enabled" == enabled ]]; then BACKGROUND_STATE+='�������ÿ�������'; else BACKGROUND_STATE+='��δ���ÿ�������'; fi
            fi
            ;;
        SB_UPDATE_ACTION)
            cron_content=''
            if command -v crontab >/dev/null 2>&1; then
                if ! read_root_crontab; then BACKGROUND_PRESENT=1; BACKGROUND_STATE='�޷���ȡ crontab������״̬δ֪'; return 0; fi
                cron_content=$ROOT_CRONTAB_CONTENT
            fi
            if [[ -n "$(filter_sb_update_cron 1 <<< "$cron_content")" ]]; then
                BACKGROUND_PRESENT=1
                BACKGROUND_STATE='�����ö�ʱ����'
            elif [[ -f /usr/local/bin/sb-auto-update.sh ]]; then
                BACKGROUND_PRESENT=1
                BACKGROUND_STATE='���½ű��Ѵ��ڣ�δ���ö�ʱ����'
            fi
            ;;
        WATCHTOWER_ACTION)
            if command -v docker >/dev/null 2>&1; then
                if current=$(docker inspect --format '{{.State.Status}}' watchtower 2>/dev/null); then
                    BACKGROUND_PRESENT=1
                    case "$current" in
                        running) BACKGROUND_STATE='������' ;;
                        restarting) BACKGROUND_STATE='��������' ;;
                        *) BACKGROUND_STATE='�����ã�δ����' ;;
                    esac
                fi
            fi
            ;;
    esac
}

choose_background_action() {
    local variable=$1 label=$2
    probe_background_state "$variable"
    show_background_menu "$label" "$BACKGROUND_PRESENT" "$BACKGROUND_STATE"
    require_choice "$variable" '��ѡ���̨����������س�=1��: ' 1
}

show_background_menu() {
    printf '\n%s��\n' "$1"
    printf '  ��ǰ״̬��%s\n' "${3:-δ����}"
    echo '  1) ���ã�Ĭ�ϣ�'
    if [[ "${2:-0}" == 1 ]]; then
        echo '  2) ͣ����������'
        echo '  0) ������״'
    else
        echo '  2) �����ã�����������'
    fi
}

background_action_label() {
    case "$1" in
        0) printf '������״' ;;
        1) printf '����' ;;
        2) printf '�����ã���������ͣ�ã�' ;;
    esac
}

select_scene() {
    step 'ѡ���������; / ��·'
    echo '  ���繤������·���ã�'
    echo '  1) HK / JP ��Ʒ��· �� ���ӳ���·��NextTrace / sing-box ��ѡ'
    echo '  2) LA �ȿ�����· �� ���ӳ١�������������������ѡ'
    echo '  3) DE / �����˸� �� ���� DE ר�� TCP ������������ѡ'
    echo '  4) ����������� �� ���ӳ� TCP ����������װ NextTrace / sing-box'
    echo ''
    echo '  ���й�Ӧ�ã�'
    echo '  5) Docker ���� �� NPM ������� + ����ѡ���Ӧ�ã�ԭ���ڳ�����'
    echo '     ������ VPS ����ѡ���Ƿ���Ҫ�������ȡ���ڷ��������硣'
    echo '  0) �˳��ű�'
    if [[ "${VPS_MODE:-full}" == full ]]; then
        echo '  ��ʾ��ѡ�� 1-4 �����ö�Ӧ TCP ������ fail2ban��ѡ�� 5 ���� Docker ����'
    else
        echo '  ��ʾ���˴�ֻȷ��������Χ����ǰ���������������� TCP ������ϵͳ����������'
    fi
    require_choice VPS_SCENE '��ѡ����; / ��· [0-5����Ĭ��ֵ]: '
    case "$VPS_SCENE" in
        0) exit 0 ;;
        1|hk|jp) VPS_SCENE=hk; SCENE_NAME='HK / JP ��Ʒ��·' ;;
        2|la) VPS_SCENE=la; SCENE_NAME='LA ���ӳ���·' ;;
        3|de) VPS_SCENE=de; SCENE_NAME='DE / �����˸���·' ;;
        4|minimal) VPS_SCENE=minimal; SCENE_NAME='���������' ;;
        5|domestic) VPS_SCENE=domestic; SCENE_NAME='Docker ���йܷ���' ;;
        *) die '������Ч�������� 0-5 �� hk/la/de/minimal/domestic' ;;
    esac
    info "��ѡ��$SCENE_NAME"
}

select_components() {
    if [[ "${VPS_MODE:-full}" == status ]]; then
        VPS_COMPONENTS=0 INSTALL_NEXTTRACE=0 INSTALL_SING_BOX=0
        return 0
    fi
    if [[ "$VPS_SCENE" == minimal || "$VPS_SCENE" == domestic ]]; then
        [[ "${VPS_COMPONENTS:-0}" == 0 ]] || die '�����͹��ڰ治֧�� VPS_COMPONENTS�����⹤����ѡ�񳡾� 1-3'
        VPS_COMPONENTS=0
    else
        if [[ "${VPS_MODE:-full}" == update ]]; then
            step 'ѡ��Ҫ���µĹ���'
            echo '  ֻ�����Ѱ�װ���ߣ���δ��װʱ����á���װ / �����������'
        else
            step 'ѡ��Ҫ��װ�Ĺ���'
        fi
        echo '  NextTrace���鿴����·������·��sing-box���������񼰹������ߡ�'
        echo '  1) NextTrace + sing-box��Ĭ�ϣ�'
        echo '  2) �� NextTrace'
        echo '  3) �� sing-box'
        echo '  0) ��ѡ��'
        require_choice VPS_COMPONENTS '��ѡ�񹤾� [0-3���س�=1]: ' 1
        case "$VPS_COMPONENTS" in 0|1|2|3) ;; *) die '�����ű���Ϊ 0-3' ;; esac
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
    AVAILABLE_PROFILES=(tools code media rss files monitoring notes)
    declare -gA ENABLED_PROFILES=()
    COMPOSE_PROFILE_ARGS=()
    SELECTED_PROFILE_NAMES=()
    local profile selection item
    local -a requested=()
    step "ѡ������� �� $(mode_label "${VPS_MODE:-full}")"
    echo '  ��������NPM��Nginx Proxy Manager�����������֤���������ʼ�հ�����'
    if [[ "${VPS_MODE:-full}" == status ]]; then
        echo '  ��ѡ��Ҫ���ķ����飻ȱ�����������δ����ʱ�ᱨ���쳣��'
    elif [[ "${VPS_MODE:-full}" == update ]]; then
        echo '  �������� Compose ���壻��ѡ������������ʱ���ᰴ�������ô�����������'
    else
        echo '  Watchtower �Զ������Ժ󵥶�ѡ��ѡ������������ / ���� Compose ���á�'
    fi
    echo '  1) �����빤�� �� Homepage + IT-Tools'
    echo '  2) �����й� �� Gitea'
    echo '  3) ���������� �� Navidrome + MeTube'
    echo '  4) RSS ���� �� RSSHub + Browserless + Redis'
    echo '  5) �ļ����� �� File Browser + OpenList'
    echo '  6) ������ �� Uptime Kuma + Beszel'
    echo '  7) �ʼǱ��� �� Memos'
    echo '  8) ȫ����ѡ������'
    echo '  0) ���������� NPM��Ĭ�ϣ�'
    echo '  �ɶ�ѡ������ 1,4,6��0 �� 8 �赥��ʹ�á�δѡ�е����з��񲻻ᱻж�ء�'
    require_choice SERVICE_PROFILES '��ѡ������� [�س�=0]: ' 0
    selection=${SERVICE_PROFILES//[[:space:]]/}
    case "$selection" in
        8|all) requested=("${AVAILABLE_PROFILES[@]}") ;;
        0|none) requested=() ;;
        *)
            [[ "$selection" != ,* && "$selection" != *, && "$selection" != *,,* ]] || die '����ѡ���ܰ�������'
            IFS=',' read -r -a requested <<< "$selection"
            ;;
    esac
    for item in "${requested[@]}"; do
        case "$item" in
            1|tools) profile=tools ;; 2|code) profile=code ;;
            3|media) profile=media ;; 4|rss) profile=rss ;;
            5|files) profile=files ;; 6|monitoring) profile=monitoring ;;
            7|notes) profile=notes ;; *) die "δ֪����ѡ��: $item" ;;
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
    for profile in "${SELECTED_PROFILE_NAMES[@]}"; do
        COMPOSE_PROFILE_ARGS+=(--profile "$profile")
    done
    if [[ "${WATCHTOWER_ACTION:-0}" == 1 ]]; then
        COMPOSE_PROFILE_ARGS+=(--profile watchtower)
    fi
}

profile_label() {
    case "$1" in
        tools) printf '�����빤�ߣ�Homepage��IT-Tools��' ;;
        code) printf '�����йܣ�Gitea��' ;;
        media) printf '���������أ�Navidrome��MeTube��' ;;
        rss) printf 'RSS ���ģ�RSSHub��Browserless��Redis��' ;;
        files) printf '�ļ�������File Browser��OpenList��' ;;
        monitoring) printf '�����أ�Uptime Kuma��Beszel��' ;;
        notes) printf '�ʼǱ�����Memos��' ;;
    esac
}

validate_options() {
    local variable
    for variable in UPGRADE_SYSTEM INSTALL_STARSHIP RESET_STARSHIP_CONFIG; do
        case "${!variable:-0}" in 0|1) ;; *) die "$variable ��֧�� 0 �� 1" ;; esac
    done
    for variable in IPERF3_ACTION WATCHTOWER_ACTION SB_UPDATE_ACTION; do
        case "${!variable:-0}" in 0|1|2) ;; *) die "$variable ��֧�� 0/1/2������/����/ͣ�ã�" ;; esac
        if [[ "${VPS_MODE:-full}" == status || "${VPS_MODE:-full}" == update ]]; then
            [[ "${!variable:-0}" == 0 ]] || die '���/����ģʽ��������̨���ԣ��뽫 ACTION ��Ϊ 0����ͣ��ʹ�����ģʽ'
        fi
    done
    SERVICE_WAIT_TIMEOUT=${SERVICE_WAIT_TIMEOUT:-300}
    if [[ ! "$SERVICE_WAIT_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || (( SERVICE_WAIT_TIMEOUT > 3600 )); then die 'SERVICE_WAIT_TIMEOUT ����Ϊ 1-3600 ��'; fi
    if [[ "$VPS_SCENE" != domestic ]]; then
        IPERF3_PORT=${IPERF3_PORT:-5201}
        if [[ ! "$IPERF3_PORT" =~ ^[1-9][0-9]{3,4}$ ]] || (( IPERF3_PORT < 1024 || IPERF3_PORT > 65535 )); then die 'IPERF3_PORT ������ 1024-65535 ������'; fi
    fi
    STACK_DIR=${STACK_DIR:-/root}
    [[ "$STACK_DIR" == /* && "$STACK_DIR" != / && "$STACK_DIR" != *$'\n'* ]] || die 'STACK_DIR ����Ϊ�Ǹ�Ŀ¼�ľ���·��'
    # Ĭ��ʹ��ԭʼ����Դ���ɲ������ṩ���ŵľ���վ JSON ���顣
    DOCKER_MIRRORS=${DOCKER_MIRRORS:-[]}
    if [[ -z "${MEMOS_IMAGE:-}" && -f "$STACK_DIR/docker-compose.yml" ]]; then
        MEMOS_IMAGE=$(awk '/^  memos:/ {inside=1; next} inside && /^    image:/ {print $2; exit}' "$STACK_DIR/docker-compose.yml")
        if [[ "$MEMOS_IMAGE" == neosmemo/memos:latest ]]; then
            if [[ -d "$STACK_DIR/memos/data" ]] && find "$STACK_DIR/memos/data" -type f -print -quit | grep -q .; then
                if [[ "${VPS_MODE:-full}" != status && "${VPS_MODE:-full}" != update && -n "${ENABLED_PROFILES[notes]+x}" ]]; then
                    die '���оɰ� Memos ���ݣ����ȱ��ݲ��˶�����·��������ʽ���� MEMOS_IMAGE������ 0.22 �������� 0.25.3�������� 0.31.0��'
                fi
            else
                MEMOS_IMAGE=neosmemo/memos:0.31.0
            fi
        fi
    fi
    MEMOS_IMAGE=${MEMOS_IMAGE:-neosmemo/memos:0.31.0}
    [[ "$MEMOS_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9./:@_-]+$ ]] || die 'MEMOS_IMAGE ����Ϊ��Ч�������ã������հ׻� Shell �ַ�'
}

print_plan() {
    local profile tools=''
    step '����ִ�з���'
    info "������$(mode_label "${VPS_MODE:-full}")"
    info "��; / ��·��$SCENE_NAME"
    if [[ "${VPS_MODE:-full}" == full ]]; then
        info 'ϵͳ���ã�������������������APT �������¡��������ߡ��Զ���ȫ���¡���־���� 100M'
        if [[ "${UPGRADE_SYSTEM:-1}" == 1 ]]; then info 'ϵͳ��������ִ������'; else info 'ϵͳ����������������'; fi
        if [[ "${INSTALL_STARSHIP:-1}" == 1 ]]; then info '�ն���ʾ�������� Starship'; else info '�ն���ʾ�������� Starship'; fi
    elif [[ "$VPS_MODE" == components ]]; then
        info '����װ��ѡ�����������������ϵͳ�����޸�����������ȫ���Ի� TCP ����'
    elif [[ "$VPS_MODE" == status ]]; then
        info 'ֻ����飬����װ���������޸����û��̨����'
    elif [[ "$VPS_MODE" == update ]]; then
        info '�����������ã���������ѡ���Ѳ������ / ���񣬲����³�ʼ��ϵͳ'
    fi
    if [[ "$VPS_SCENE" == domestic ]]; then
        case "${VPS_MODE:-full}" in
            full|components) info '������������ / ��װ Docker �� Compose���������ò�������ѡ����' ;;
            status) info '�����������ȡ���� Compose�������ѡ�������� / ����״̬' ;;
            update) info '�����������ȡ���� Compose����ȡ��ѡ����������������' ;;
        esac
        info '����Χ��NPM�����������֤�������'
        for profile in "${SELECTED_PROFILE_NAMES[@]}"; do
            printf '  + %s\n' "$(profile_label "$profile")"
        done
        info "Watchtower �Զ����£�$(background_action_label "$WATCHTOWER_ACTION")"
        info "����Ŀ¼��$STACK_DIR"
    else
        if [[ "${VPS_MODE:-full}" == full ]]; then info "��·���ã�Ӧ�� $SCENE_NAME �� TCP ���������� fail2ban"; fi
        [[ "$INSTALL_NEXTTRACE" != 1 ]] || tools='NextTrace'
        [[ "$INSTALL_SING_BOX" != 1 ]] || tools="${tools:+$tools��}sing-box"
        case "${VPS_MODE:-full}" in
            full|components) info "��װ���ߣ�${tools:-��}" ;;
            update) info "���¹��ߣ�${tools:-��}" ;;
            status) info '��鷶Χ��fail2ban��iperf3��cron��TCP ӵ�����ơ�sing-box ��ʱ����' ;;
        esac
        if [[ "${VPS_MODE:-full}" == full || "$VPS_MODE" == components ]]; then
            info "iperf3 ���ٷ���$(background_action_label "$IPERF3_ACTION")���˿� $IPERF3_PORT��"
            info "sing-box ÿ�ո��£�$(background_action_label "$SB_UPDATE_ACTION")"
        fi
    fi
    if [[ "${VPS_MODE:-full}" == full || "$VPS_MODE" == components ]]; then
        info 'δѡ����������ж�أ���̨����ѡ��ͣ�á���ֹͣ��Ӧ����������'
    fi
}

preflight() {
    [[ $EUID -eq 0 ]] || die '���� root �û����д˽ű�'
    [[ -r /etc/os-release ]] || die '�޷���ȡ /etc/os-release'
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        debian:*) dpkg --compare-versions "$VERSION_ID" ge 11 || die '��Ҫ Debian 11+' ;;
        ubuntu:*) dpkg --compare-versions "$VERSION_ID" ge 22.04 || die '��Ҫ Ubuntu 22.04+' ;;
        *) die '�˽ű���֧�� Debian 11+ / Ubuntu 22.04+' ;;
    esac
    [[ -n "${VERSION_CODENAME:-}" ]] || die 'ȱ��ϵͳ�汾���� VERSION_CODENAME'
    [[ -d /run/systemd/system ]] || die '��Ҫ�����е� systemd���������������� TCP ��������������֧�� systemd ����'
}

collect_hostname() {
    NEW_HOSTNAME=${VPS_HOSTNAME:-}
    if [[ -z "$NEW_HOSTNAME" ]]; then
        read_tty NEW_HOSTNAME '����������������ֱ�ӻس�������: ' ''
    fi
    [[ -z "$NEW_HOSTNAME" ]] || valid_hostname "$NEW_HOSTNAME" || die '��������ʽ��Ч'
}

collect_homepage() {
    HOMEPAGE_HOST=${HOMEPAGE_HOST:-}
    # ���ݱ��ű���ǰ���ɵ� Compose��׷������������Ҳ���뱣������������
    if [[ -z "$HOMEPAGE_HOST" && -f "${STACK_DIR:-/root}/docker-compose.yml" ]]; then
        HOMEPAGE_HOST=$(awk '/^[[:space:]]*- HOMEPAGE_ALLOWED_HOSTS=/ {
            sub(/^[[:space:]]*- HOMEPAGE_ALLOWED_HOSTS=/, ""); print; exit
        }' "${STACK_DIR:-/root}/docker-compose.yml")
    fi
    if [[ -n "${ENABLED_PROFILES[tools]+x}" ]]; then
        require_choice HOMEPAGE_HOST '������ Homepage �������� nav.example.com��: '
        is_valid_domain "$HOMEPAGE_HOST" || die 'Homepage ��������Ч DNS ����������Э�顢�˿ڡ�·����ͨ���'
    else
        # δ���� tools ʱ��Ҫ��˽����������������ǰӦ�������в�ָ��������
        HOMEPAGE_HOST=${HOMEPAGE_HOST:-nav.example.com}
    fi
    is_valid_domain "$HOMEPAGE_HOST" || die '���� Homepage �����޷�ʶ����ͨ�� HOMEPAGE_HOST ָ����Ч����'
}

backup_file() {
    local target=$1 backup
    if [[ -f "$target" ]]; then
        backup=$(mktemp "${target}.bak.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
        cp -a -- "$target" "$backup" || { rm -f -- "$backup"; return 1; }
    fi
}

# ���ļ�����ֻ�����ݸı�ű��ݺ�д�룻У�������ʧ��ʱ�ָ��ļ�������ԭ״̬��
apply_service_files() {
    local service=$1 validator=$2 enable_service=$3
    shift 3
    local candidate target backup index original_active=0 original_enabled=0 changed=0
    local -a targets=() backups=() candidates=()
    systemctl is-active --quiet "$service" && original_active=1
    systemctl is-enabled --quiet "$service" && original_enabled=1
    # ���б��ݳɹ�����滻�κ�Ŀ�꣬����ڶ��ݱ���ʧ�����°�����á�
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
        error "$service ����У��ʧ�ܣ��ָ������޸�"
        restore_service_files
        return 1
    fi
    if (( changed == 1 || original_active == 0 )); then
        if [[ "$service" == iperf3-server.service ]]; then systemctl daemon-reload || { restore_service_files; return 1; }; fi
        if ! systemctl restart "$service" || ! service_is_ready "$service"; then
            error "$service ����ʧ�ܣ��ָ�ԭ���ú�����״̬"
            restore_service_state
            return 1
        fi
    else
        info "$service ����δ�仯�������У��������ݡ�д�������"
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
            error "$service ԭ�����ѻָ���������ָ�ʧ�ܣ����� journalctl -u $service"; return 1
        fi
    else
        systemctl stop "$service" || return 1
    fi
    if (( original_enabled == 0 )); then systemctl disable "$service" || return 1; fi
}

# ʹ�� apply_service_files �ľֲ����飨Bash ��̬�����򣩣����Ӵ�δ����������ļ���
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
    (( failed == 0 )) || error '�������ûָ�ʧ�ܣ���ʹ�ñ����� .bak �ļ��˹��ָ�'
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
    error 'iperf3 δ��������Ŀ������ TCP ����'
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
step "�޸�������"
[[ -n "$NEW_HOSTNAME" ]] || { info "�����������޸�"; return 0; }
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

    # ��ֹ�ƾ���� cloud-init ��������ָ��Ƴ����·��ľ���������
    if command -v cloud-init &>/dev/null; then
        install -d -m 0755 /etc/cloud/cloud.cfg.d
        candidate=$(mktemp /etc/cloud/cloud.cfg.d/.vps-hostname.XXXXXX)
        printf 'preserve_hostname: true\n' > "$candidate"
        install_file_if_changed "$candidate" /etc/cloud/cloud.cfg.d/99-vps-preserve-hostname.cfg
    fi

    # FQDN ��ǰ�����������ں󣬱��� sudo �� "unable to resolve host"��
    candidate=$(mktemp /etc/.vps-hosts.XXXXXX)
    awk -v names="$HOSTS_NAMES" '
        $1 == "127.0.1.1" { if (!found++) print "127.0.1.1\t" names; next }
        { print }
        END { if (!found) print "127.0.1.1\t" names }
    ' /etc/hosts > "$candidate"
    install_file_if_changed "$candidate" /etc/hosts
    info "������������Ϊ: $NEW_HOSTNAME��/etc/hosts ��ͬ����"
}

install_base() {
# ---------- 2. ϵͳ���� & ��װ�������� ----------
step "ϵͳ���� & ��װ��������"
# �ǽ���ģʽ������ conffile ��ͻ������ needrestart ���������ű�
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
# ---------- ����������������ϵͳ���� ----------
case "${UPGRADE_SYSTEM:-1}" in
    0|1) ;;
    *) error "UPGRADE_SYSTEM ��֧�� 0 �� 1"; exit 1 ;;
esac
if ! apt-get update -o APT::Update::Error-Mode=any; then
    error "��������������ʧ�ܣ�ֹͣ��ʼ�������� APT ���������"
    exit 1
fi
if [[ "${UPGRADE_SYSTEM:-1}" == 1 ]]; then
    if ! apt-get upgrade -y -o Dpkg::Options::="--force-confold"; then
        error "ϵͳ����ʧ�ܣ�ֹͣ��ʼ�������� APT ���������"
        exit 1
    fi
else
    info "��ͨ�� UPGRADE_SYSTEM=0 ����ϵͳ�������Ը�����������װ���蹤��"
fi
# ---------- ϵͳ������������ ----------
apt-get install -y curl wget ca-certificates tar
if [[ "${VPS_MODE:-full}" == full ]]; then apt-get install -y unattended-upgrades; fi
if [[ "$VPS_SCENE" == domestic ]]; then
    apt-get install -y gnupg jq python3
else
    if [[ "${VPS_MODE:-full}" == full ]]; then apt-get install -y fail2ban python3-systemd kmod; fi
    if [[ "${IPERF3_ACTION:-0}" == 1 ]]; then apt-get install -y iperf3 iproute2; fi
    if [[ "${SB_UPDATE_ACTION:-0}" == 1 ]]; then apt-get install -y cron; fi
fi
info "ϵͳ���¼��������߰�װ���"
}

configure_tcp() {
# ---------- 3. TCP ���� ----------
step "TCP ���� ($SCENE_NAME)"

# ���Լ��� BBR �� fq�������� VPS ������������ͳһ���ƣ�ʵ�����޷��޸ġ�
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
    warn "��ǰ�ں�δ�ṩ BBR��������ӵ�������㷨: $TCP_CC"
else
    TCP_CC=""
    warn "������δ��ʵ����¶ TCP ӵ�����ƽӿڣ��޷���ʵ�������� BBR"
fi

install -d -m 0755 /etc/sysctl.d
SYSCTL_TARGET=/etc/sysctl.d/99-vps-tuning.conf
SYSCTL_FILE=$(mktemp /etc/sysctl.d/.vps-tuning.XXXXXX)
APPLIED_SYSCTL_KEYS=()
APPLIED_SYSCTL_COUNT=0
SKIPPED_SYSCTL_COUNT=0

# ֻ���ں�ʵ�ʱ�¶������д��Ĳ�������־û����á�
# ������ LXC/OpenVZ ������������Ҳ��������� sysctl ʧ�ܶ��ж�������ʼ����
try_sysctl() {
    local key=$1
    local value=$2
    local output

    if ! sysctl -n "$key" >/dev/null 2>&1; then
        warn "���� $key��������δ��¶�ò���"
        ((SKIPPED_SYSCTL_COUNT += 1))
        return 0
    fi

    if ! output=$(sysctl -w "$key=$value" 2>&1); then
        warn "���� $key��$output"
        ((SKIPPED_SYSCTL_COUNT += 1))
        return 0
    fi

    printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_FILE"
    APPLIED_SYSCTL_KEYS+=("$key")
    ((APPLIED_SYSCTL_COUNT += 1))
}

cat > "$SYSCTL_FILE" << 'SYSCTL_EOF'
# ============================================================
# VPS TCP ���� - ������ڰ�����ѡ�������
# ��������ı�ʵ����Ӫ��·��
# �����������ں�ʵ��֧��������д��Ĳ���
# ============================================================
SYSCTL_EOF

printf '\n# ---------- ӵ������ ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.core.default_qdisc fq
if [[ -n "$TCP_CC" ]]; then
    try_sysctl net.ipv4.tcp_congestion_control "$TCP_CC"
fi

printf '\n# ---------- ���Ӷ��� ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.core.somaxconn 4096
try_sysctl net.ipv4.tcp_max_syn_backlog 4096
try_sysctl net.core.netdev_max_backlog 4096

printf '\n# ---------- Keepalive ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.ipv4.tcp_keepalive_time 600
try_sysctl net.ipv4.tcp_keepalive_intvl 30
try_sysctl net.ipv4.tcp_keepalive_probes 5

printf '\n# ---------- ����������·������ ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.ipv4.tcp_syncookies 1
try_sysctl net.ipv4.tcp_mtu_probing 1
try_sysctl net.ipv4.tcp_ecn 2

printf '\n# ---------- ��վ�˿� ----------\n' >> "$SYSCTL_FILE"
try_sysctl net.ipv4.ip_local_port_range "10000 65535"

printf '\n# ---------- TCP �Զ����ڻ��������ޣ�������ѡ��----------\n' >> "$SYSCTL_FILE"
# ����ԭ�汾�Ļ��������죺HK/���� 16 MiB��LA/DE 32 MiB��
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

printf '\n# ---------- �ڴ���Ϊ ----------\n' >> "$SYSCTL_FILE"
try_sysctl vm.swappiness 10

if (( APPLIED_SYSCTL_COUNT == 0 )); then
    rm -f "$SYSCTL_FILE"
    warn "��������ֹ�޸�ȫ��Ŀ������������� TCP ���Ų�����������ʼ��"
else
    install_file_if_changed "$SYSCTL_FILE" "$SYSCTL_TARGET"
    SYSCTL_FILE=$SYSCTL_TARGET
    info "TCP ������Ӧ�� $APPLIED_SYSCTL_COUNT ����� $SKIPPED_SYSCTL_COUNT ��"
    info "�����ɹ�����д�� $SYSCTL_FILE"

    # /etc/sysctl.conf �� sysctl --system �н������ء���ע���ѳɹ��ӹܵ�ͬ������
    SYSCTL_BACKED_UP=false
    if [[ -f /etc/sysctl.conf ]]; then
        for key in "${APPLIED_SYSCTL_KEYS[@]}"; do
            escaped_key=${key//./\\.}
            if grep -qE "^[[:space:]]*${escaped_key}[[:space:]]*=" /etc/sysctl.conf; then
                if [[ "$SYSCTL_BACKED_UP" == false ]]; then
                    cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
                    SYSCTL_BACKED_UP=true
                fi
                sed -i -E "s|^[[:space:]]*(${escaped_key})[[:space:]]*=|# [vps-tuning �ѽӹ�] &|" /etc/sysctl.conf
            fi
        done
        [[ "$SYSCTL_BACKED_UP" == true ]] && info "�ѱ��� sysctl.conf������ע�ͳɹ��ӹܵ�ͬ������"
    fi
fi

# ��֤����ʹ�õ�ӵ�������㷨
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if [[ "$TCP_CC" == "bbr" && "$CURRENT_CC" == "bbr" ]]; then
    info "BBR �ѳɹ�����"
elif [[ -n "$CURRENT_CC" ]]; then
    warn "��ǰӵ�������㷨: $CURRENT_CC"
else
    warn "�޷���ȡӵ�������㷨�������� VPS ����������"
fi
}

configure_iperf3() {
# ---------- ���� iperf3 ��̨���� ----------
# �������нű�ǰͨ�� IPERF3_PORT ���������޸Ķ˿ڣ�DynamicUser ��Ҫ����Ȩ�˿ڡ�
IPERF3_PORT="${IPERF3_PORT:-5201}"
if [[ ! "$IPERF3_PORT" =~ ^[1-9][0-9]{3,4}$ ]] || (( IPERF3_PORT < 1024 || IPERF3_PORT > 65535 )); then
    error "IPERF3_PORT ������ 1024-65535 ֮�����������ǰ: $IPERF3_PORT��"
    exit 1
fi

local listeners current_pid
listeners=$(ss -H -ltnp "sport = :${IPERF3_PORT}") || return 1
current_pid=$(systemctl show --property=MainPID --value iperf3-server.service 2>/dev/null || true)
if [[ -n "$listeners" ]]; then
    if [[ ! "$current_pid" =~ ^[1-9][0-9]*$ ]] || grep -qv "pid=${current_pid}," <<< "$listeners"; then
        error "�˿� $IPERF3_PORT �ѱ���������ռ�ã������� iperf3.service�����뻻�� IPERF3_PORT ���ȴ������з���"
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
info "iperf3 ���ں�̨���в�����Ϊ�����������˿�: $IPERF3_PORT��"
warn "iperf3 Ĭ����������֤���������� IP ���� TCP/UDP $IPERF3_PORT"
}

install_nexttrace() {
# ---------- 4. ��װ NextTrace ----------
step "��װ NextTrace"
if command -v nexttrace &>/dev/null || command -v nxtrace &>/dev/null; then
    warn "NextTrace �Ѱ�װ������"
else
    run_installer https://nxtrace.org/nt || {
        error "NextTrace ��װ��ʧ��"
        return 1
    }
    if command -v nexttrace &>/dev/null || command -v nxtrace &>/dev/null; then
        info "NextTrace ��װ���"
    else
        error "NextTrace δ��⵽����ѡ��װδ���"
        return 1
    fi
fi
}

# 233boy ��ʵ���ں˷��� /etc/sing-box/bin��PATH �е� sing-box ͨ���ǹ����ű���
# ���Թ�������Ƿ���ڻ�װ���˳��뵥���жϳɹ�������ȡ������ڵ����á�
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
    # �����ű��� version ��������ͬ��ֱ��ִ���ںˣ�����ʱҲ����������
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
        missing) error 'δ��⵽��ִ�е� sing-box �ںˣ���װδ���' ;;
        invalid-core) error 'sing-box �ں˰汾���δͨ������������˹������' ;;
        inactive) error 'sing-box �ں˿��ã��� sing-box.service δ���У���װδͨ��������' ;;
    esac
    info '���ڷ������ϼ�飺systemctl status sing-box.service --no-pager'
    info '�������ǰ�뱣�����нڵ��ļ������ű�����Ϊ�޸�״̬���Զ���װ��'
}

install_singbox() {
    step '��װ sing-box'
    local installer_status=0
    if probe_singbox_installation; then
        info "sing-box �Ѱ�װ��$SB_CORE_VERSION�������������У�������װ"
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
            warn "��װ���˳���Ϊ $installer_status��ʵ���ں˺ͷ��������ͨ����������ʼ��"
        fi
        info "sing-box ��װ��ɣ�$SB_CORE_VERSION��������������"
        return 0
    fi
    if (( installer_status != 0 )); then
        error "sing-box ��װ���˳���Ϊ $installer_status��ʵ�ʰ�װ���Ҳδͨ��"
    fi
    report_singbox_problem
    return 1
}

configure_fail2ban() {
# ---------- 6. ���� fail2ban ----------
step "���� fail2ban"

install -d -m 0755 /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d

# ʹ�������ص� .local drop-in���������û����� jail.local������ ignoreip Ҳ�ᱣ����
local jail_candidate db_candidate
jail_candidate=$(mktemp /etc/fail2ban/jail.d/.vps-jail.XXXXXX)
db_candidate=$(mktemp /etc/fail2ban/fail2ban.d/.vps-db.XXXXXX)
cat > "$jail_candidate" << 'EOF'
[DEFAULT]
ignoreself = true
usedns = no

# �״η� 1 Сʱ���ظ������Զ��� 1��2��4... ��������� 7 �졣
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5

[sshd]
enabled = true
# ͳһ�� journald ��ȡ SSH ��־������û�� /var/log/auth.log �ľ���ϵͳ��
backend = systemd
# �����Դ�����ж˿ڣ������Զ��� SSH �˿ڡ�
banaction = %(banaction_allports)s
EOF

# ���ݿⱣ�� 30 �죬����֧�ֵ��������ͬʱ��������������
cat > "$db_candidate" << 'EOF'
[Definition]
dbpurgeage = 2592000
EOF

apply_service_files fail2ban validate_fail2ban 1 \
    "$jail_candidate" /etc/fail2ban/jail.d/99-vps-sshd.local \
    "$db_candidate" /etc/fail2ban/fail2ban.d/99-vps-local.local || return 1
info "fail2ban �����ò�������SSH ���������� 7 �죩"
}

# �ֶ����ºͶ�ʱ������������ʱ����º�ķ������ա�
acquire_sb_update_lock() {
    exec 9>/run/lock/sb-auto-update.lock || return 1
    local result=0
    flock -n -E 75 9 || result=$?
    if (( result == 75 )); then return 75; fi
    if (( result != 0 )); then error '�޷�ȡ�� sing-box ������'; return 1; fi
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
    error 'sing-box ���º��ں˻������ʧ�ܣ����� sing-box.service ��־'
    return 1
}

singbox_update_commands() {
    local part caddy_active=0
    [[ -x /usr/local/bin/sb ]] || { error 'δ�ҵ���ִ�е� sb �����ű�'; return 1; }
    for part in sh core; do
        info "���� sing-box��$part"
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
    acquire_sb_update_lock || { error '���� sing-box �����������У����޷�ȡ����'; return 1; }
    singbox_update_commands
)

configure_sb_update() {
    step '���� sing-box �Զ����½ű�'
    [[ -x /usr/local/bin/sb ]] || { error 'δ�ҵ���ִ�е� sb �����ű�'; return 1; }
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
if (( lock_status == 75 )); then info '���и��������������У���������'; exit 0; fi
(( lock_status == 0 )) || exit 1
LOG_FILE=/var/log/sb-update.log
if [[ -f "$LOG_FILE" ]]; then
    log_size=$(stat -c '%s' "$LOG_FILE") || exit 1
    if (( log_size >= 5 * 1024 * 1024 )); then mv -f -- "$LOG_FILE" "${LOG_FILE}.1" || exit 1; fi
fi
exec >>"$LOG_FILE" 2>&1
date '+%Y-%m-%d %H:%M:%S ��ʼ����'
if singbox_update_commands; then
    info '������ɣ�sing-box �ں˼�������ͨ��'
else
    error '����ʧ�ܻ����δ������������־'
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
    info 'sing-box �Զ����½ű��Ѳ���ÿ�� 04:00 ִ�У�����������ʱ�ͷ������գ�'
}


configure_security() {
    step '�Զ���ȫ���£��������и�����Դ����������������'
    local candidate
    local -a apt_files=()
    # �����Ƿ��а���û��� 20auto-upgrades / 50unattended-upgrades��
    # ����û�д�ͳ��������ʱά�����ű��Ķ��� drop-in��
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
        info 'APT ���ȶ�ʱ�������У��Զ������Ƿ����ü�������Դ���� APT ����'
    else
        warn 'APT ���ȶ�ʱ��δȫ�����У��Զ���ȫ���¿��ܲ���ִ�У��ѱ���ԭ���Ȳ��ԣ����� apt-daily.timer / apt-daily-upgrade.timer'
    fi

    step 'journald ��־���� 100M'
    install -d -m 0755 /etc/systemd/journald.conf.d
    candidate=$(mktemp /etc/systemd/journald.conf.d/.vps-limit.XXXXXX)
    printf '[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=100M\n' > "$candidate"
    apply_service_files systemd-journald validate_none 0 "$candidate" /etc/systemd/journald.conf.d/limit.conf
}

install_docker() {
# ---------- 3. ��װ Docker & Compose ----------
step "��װ Docker & Compose"

if command -v docker &>/dev/null; then
    warn "Docker �Ѱ�װ: $(docker --version)"
else
    info "ʹ�� Docker �ٷ� APT �ֿⰲװ Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc || {
        error "Docker �ٷ��ֿ�ǩ����Կ����ʧ�ܣ��������������"
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
    info "Docker ��װ���: $(docker --version)"
fi

# ���� Docker Ҳ������� Compose���κ�ȱ��Ӧ���޸� daemon ����ǰ�����
ensure_compose_plugin || return 1
command -v dockerd >/dev/null 2>&1 || { error 'δ�ҵ����� dockerd�������Ҫ�󱾻� rootful Docker Engine'; return 1; }

# ֻʹ�ò�������ʽ�ṩ�ľ���վ��δ�ṩʱ�������� mirrors��
jq -e 'type == "array" and all(.[]; type == "string" and test("^https?://[^[:space:]]+$"))' <<< "$DOCKER_MIRRORS" >/dev/null || die 'DOCKER_MIRRORS ����Ϊ HTTP(S) ��ַ�� JSON ����'
# ���� Docker daemon����ѡ������� + ��־���ƣ�
mkdir -p /etc/docker
# �����ű������úϲ������� daemon.json��д��ǰУ�飬����ʧ����ع�
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
        error "���� daemon.json �޷�������δ�޸�ԭ�ļ�"
        exit 1
    fi
else
    cp "${DAEMON_FRAGMENT}" "${DAEMON_CANDIDATE}"
fi

if ! jq empty "${DAEMON_CANDIDATE}" 2>/dev/null || \
   ! dockerd --validate --config-file "${DAEMON_CANDIDATE}" &>/dev/null; then
    rm -f "${DAEMON_FRAGMENT}" "${DAEMON_CANDIDATE}"
    error "�ϲ���� daemon.json δͨ��У�飬ԭ����δ�޸�"
    exit 1
fi

rm -f -- "$DAEMON_FRAGMENT"
apply_service_files docker validate_docker 1 "$DAEMON_CANDIDATE" "$DAEMON_FILE" || return 1
info "Docker daemon �Ѻϲ����ã��������þ���վ + ȫ����־���ƣ�"

# ��֤ compose ���
if docker compose version &>/dev/null; then
    info "Docker Compose ����: $(docker compose version --short)"
else
    error "Docker Compose ���δ��װ������ Docker �汾"
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
            docker compose version >/dev/null 2>&1 || { error 'Compose �����װ���Բ�����'; return 1; }
            return 0
        fi
    done
    error '���� Docker ȱ�� Compose v2+ �������ǰ APT Դû�п��ð����������ö�Ӧ Docker �ֿ⡣��δ�޸� daemon ���á�'
    return 1
}

watchtower_api_version() {
    local version minimum minor
    version=$(docker version --format '{{.Server.APIVersion}}') || return 1
    [[ "$version" =~ ^1\.([0-9]+)$ ]] || { error '�޷���ȡ Docker ����� API �汾' >&2; return 1; }
    minor=${BASH_REMATCH[1]}
    # Watchtower 1.7.1 Ĭ�� 1.25 ���� Docker 29 ���ܣ�����ʹ�ü��ݵ� 1.44��
    minimum=$(docker version --format '{{.Server.MinAPIVersion}}') || return 1
    [[ "$minimum" =~ ^1\.([0-9]+)$ ]] || { error '�޷���ȡ Docker ��� API �汾' >&2; return 1; }
    if (( BASH_REMATCH[1] > 44 )); then error 'Docker ��� API �Ѹ��� Watchtower ���ݷ�Χ����ͣ�û�����������' >&2; return 1; fi
    if (( minor < 25 )); then return 1; fi
    if (( minor > 44 )); then minor=44; fi
    DOCKER_API_VERSION="1.$minor" docker version >/dev/null || return 1
    printf '1.%s\n' "$minor"
}

prepare_filebrowser_storage() {
    [[ -n "${ENABLED_PROFILES[files]+x}" ]] || return 0
    local directory
    for directory in "$STACK_DIR/Filebrowser" "$STACK_DIR/Filebrowser/config" "$STACK_DIR/Filebrowser/database"; do
        [[ ! -L "$directory" ]] || { error "�ܾ��޸ķ�������Ŀ¼��$directory"; return 1; }
        if [[ ! -d "$directory" ]]; then install -d -m 0750 -o 0 -g 0 "$directory" || return 1; fi
    done
    # FileBrowser �� root ���� /root��������������Ŀ¼�� /root ������Ȩ��Ȩ�ޡ�
}

# Compose �ƶ�Ŀ¼����ʹ��ԭ��Ŀ�� Redis �����������д�����ù��ֶ��������á�
resolve_stack_identity() {
    local configuration identity file_project='' file_volume='' containers project='' redis_project='' volume=''
    local -a project_args=()
    local fallback=${STACK_DIR%/}
    fallback=${fallback##*/}
    [[ "${STACK_DIR%/}" != /root ]] || fallback=stacks
    containers=$(docker ps --all --format '{{.Names}}') || return 1
    if grep -qx npm <<< "$containers"; then
        project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' npm) || return 1
        [[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { error '���� npm ����ȱ����Ч Compose ��Ŀ��ǩ��ֹͣ��������'; return 1; }
    fi
    if grep -qx redis <<< "$containers"; then
        redis_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' redis) || return 1
        [[ "$redis_project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { error '���� redis ����ȱ����Ч Compose ��Ŀ��ǩ��ֹͣ��������'; return 1; }
        [[ -z "$project" || "$project" == "$redis_project" ]] || { error '���� npm �� redis ���ڲ�ͬ��Ŀ��ֹͣ��������'; return 1; }
        project=$redis_project
        volume=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}' redis) || return 1
        [[ -n "$volume" ]] || { error '���� Redis �� /data δʹ�������������Ⱥ˶����ݣ�ֹͣ����'; return 1; }
    fi
    if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
        if [[ -n "$project" ]]; then
            project_args=(--project-name "$project")
        elif [[ -z "${COMPOSE_PROJECT_NAME:-}" && "${STACK_DIR%/}" == /root ]] && ! grep -qE '^name[[:space:]]*:' "$STACK_DIR/docker-compose.yml"; then
            # ��ģ��û�� name����ʹͣ��ʱ��ɾ��������Ǩ�� /root �������þ�Ĭ����Ŀ stacks��
            project_args=(--project-name stacks)
        fi
        configuration=$(docker compose "${COMPOSE_ENV_ARGS[@]}" "${project_args[@]}" --profile '*' config --format json) || return 1
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
    [[ "$STACK_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { error 'Compose ��Ŀ��ֻ��ʹ��Сд��ĸ�����֡��»��ߺ����ַ���������ĸ�����ֿ�ͷ'; return 1; }
    [[ -z "$project" || "$STACK_PROJECT_NAME" == "$project" ]] || { error 'COMPOSE_PROJECT_NAME ��������������Ŀ����ͬ��ֹͣ����'; return 1; }
    if [[ -z "$volume" && "$file_project" == "$STACK_PROJECT_NAME" ]]; then volume=$file_volume; fi
    STACK_REDIS_VOLUME_NAME=${volume:-${STACK_PROJECT_NAME}_redis-data}
    [[ "$STACK_REDIS_VOLUME_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { error '�޷�ʶ������ Redis ���������ƣ�ֹͣ����'; return 1; }
}

deploy_services() {
# ֻ����Ĭ��·������أ����Զ���Ǩ�����Ǿ����ݡ�
if [[ "${STACK_DIR%/}" == /root && ! -f "$STACK_DIR/docker-compose.yml" && -f /opt/stacks/docker-compose.yml ]]; then
    error '��⵽ /opt/stacks �ľɲ�������ͣ������ Compose��.browserless.env ��Ӧ������Ǩ�� /root������Ǩ�� /root/Music��OpenList ����Ǩ�� /root/OpenList��Redis ����ԭ��������'
    error '�ű������Զ���Ǩ���ļ�����������Ŀ¼��ͨ�� STACK_DIR ָ����Ӧ�ð�Ŀ¼����������������Ⱥ˶Բ�Ǩ�����ݡ�'
    return 1
fi
mkdir -p "${STACK_DIR}"

# Ϊ RSSHub / Browserless ���ɹ���������ƣ��������ڷ������ϣ�����ʱ���á�
ensure_browserless_env() {
    local env_file=$1 token temp_file

    if [[ -e "$env_file" ]]; then
        if [[ $(wc -l < "$env_file") -ne 1 ]] || \
           ! grep -qxE 'BROWSERLESS_TOKEN=[0-9a-f]{64}' "$env_file"; then
            error "Browserless �����ļ���ʽ��Ч�������ļ�����Ҫ���������ݣ�: $env_file"
            return 1
        fi
        chmod 0600 "$env_file"
        return 0
    fi

    token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    if [[ ! "$token" =~ ^[0-9a-f]{64}$ ]]; then
        error "Browserless �����������ʧ�ܣ�δ��������"
        return 1
    fi
    temp_file=$(mktemp "${env_file}.XXXXXX")
    printf 'BROWSERLESS_TOKEN=%s\n' "$token" > "$temp_file"
    chmod 0600 "$temp_file"
    mv -f -- "$temp_file" "$env_file"
}

BROWSERLESS_ENV_FILE="${STACK_DIR}/.browserless.env"
ensure_browserless_env "$BROWSERLESS_ENV_FILE" || die 'Browserless �����ļ������ã�ֹͣ����'
# ��ֹ�����̵�ͬ�������������Ǳ��β��𱣴�����ơ�
unset BROWSERLESS_TOKEN
COMPOSE_ENV_ARGS=(--env-file "$BROWSERLESS_ENV_FILE" -f "${STACK_DIR}/docker-compose.yml")
info "Browserless ��������Ѿ����������ڷ������ϣ���������ƣ�"
resolve_stack_identity || return 1

COMPOSE_TARGET="${STACK_DIR}/docker-compose.yml"
COMPOSE_CANDIDATE=$(mktemp "${STACK_DIR}/.compose-candidate.XXXXXX")
local watchtower_api=1.44
if [[ "$WATCHTOWER_ACTION" == 1 ]]; then watchtower_api=$(watchtower_api_version) || return 1; fi
cat > "$COMPOSE_CANDIDATE" << 'COMPOSE_EOF'
# ������־������ /etc/docker/daemon.json ȫ�����ã��������������
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

  # ==================== ������֤����� ====================
  nginx-proxy-manager:
    labels: *vps-labels
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
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', '/usr/bin/check-health']
  # ==================== �Զ������� ====================
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
    # �������� /watchtower --health-check��ֻ�����������̴�
    healthcheck:
      <<: *vps-healthcheck
  # ==================== ���˵����빤�� ====================
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
    # ���þ������õ� /api/healthcheck ��顣
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

  # ==================== �����й� ====================
  gitea:
    labels: *vps-labels
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
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', 'curl', '-fsS', '--max-time', '5', '-o', '/dev/null', 'http://127.0.0.1:3000/api/healthz']
      start_period: 120s
  # ==================== ý�������� ====================
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
    # ���þ������ü�飬������ HTTP(S) ���á�
    healthcheck:
      <<: *vps-healthcheck

  # ==================== RSS ϵͳ ====================
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
    # browserless/chrome (v1) ��ֹͣά�������� v2 chromium ����
    image: ghcr.io/browserless/chromium:latest
    container_name: browserless
    restart: always
    profiles: ["rss"]
    mem_limit: 768m
    cpus: "1.0"
    environment:
      # �� RSSHub ��������ʱ���ɵ�������ƣ�����������ʹ�ã�
      - TOKEN=${BROWSERLESS_TOKEN:?BROWSERLESS_TOKEN is required}
    healthcheck:
      <<: *vps-healthcheck
      # $$ ���������� Shell չ�������������� TOKEN��
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

  # ==================== �ļ����� ====================
  filebrowser:
    labels: *vps-labels
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    profiles: ["files"]
    # ��Ҫ���������� /root�����ſ� /root ���ļ�Ȩ�ޡ�
    user: "0:0"
    volumes:
      - /root:/srv
      - ./Filebrowser/database:/database
      - ./Filebrowser/config:/config
    restart: unless-stopped
    # ���þ������� /healthcheck.sh���������������

  openlist:
    labels: *vps-labels
    image: openlistteam/openlist:latest
    container_name: openlist
    profiles: ["files"]
    user: "0:0"
    restart: unless-stopped
    volumes:
      - ./OpenList:/opt/openlist/data
    environment:
      - UMASK=022
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD-SHELL', 'test "$$(wget -q -O - -T 5 http://127.0.0.1:5244/ping)" = pong']
  # ==================== ���ϵͳ ====================
  uptime-kuma:
    labels: *vps-labels
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    restart: unless-stopped
    profiles: ["monitoring"]
    volumes:
      - ./uptime-kuma/data:/app/data
    # ���þ������ý�����鼰�����ݿ��ʼ�������ڡ�
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
  # ==================== �ʼ�ϵͳ ====================
  memos:
    image: __MEMOS_IMAGE__
    # ���ݿ�Ǩ����Ҫ���ݺ��˹��˶԰汾·���������� Watchtower �Զ�������
    labels:
      com.centurylinklabs.watchtower.enable: "false"
    container_name: memos
    restart: unless-stopped
    profiles: ["notes"]
    volumes:
      - ./memos/data:/var/opt/memos
    healthcheck:
      <<: *vps-healthcheck
      test: ['CMD', 'wget', '-q', '-O', '/dev/null', '-T', '5', 'http://127.0.0.1:5230/healthz']
      start_period: 120s
volumes:
  redis-data:
    name: __STACK_REDIS_VOLUME_NAME__

networks:
  default:
    driver: bridge
COMPOSE_EOF

# ������ͨ���ϸ�У�飬�ɰ�ȫ�滻ռλ��
sed -i "s|__HOMEPAGE_HOST__|${HOMEPAGE_HOST}|g" "$COMPOSE_CANDIDATE"
sed -i "s|__WATCHTOWER_API__|${watchtower_api}|g; s|__MEMOS_IMAGE__|${MEMOS_IMAGE:-neosmemo/memos:0.31.0}|g" "$COMPOSE_CANDIDATE"
sed -i "s|__STACK_PROJECT_NAME__|${STACK_PROJECT_NAME}|g; s|__STACK_REDIS_VOLUME_NAME__|${STACK_REDIS_VOLUME_NAME}|g" "$COMPOSE_CANDIDATE"

if ! docker compose --env-file "$BROWSERLESS_ENV_FILE" --project-directory "$STACK_DIR" -f "$COMPOSE_CANDIDATE" "${COMPOSE_PROFILE_ARGS[@]}" config -q; then
    rm -f -- "$COMPOSE_CANDIDATE"
    error "docker-compose.yml У��ʧ�ܣ�����ԭ�ļ���δ��ȡ�������������"
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
    info 'Compose ����δ�仯���������ݺ��滻'
fi
if ! start_selected_services 0; then
    if (( compose_changed )); then
        if [[ -n "$compose_backup" ]]; then
            cp -a -- "$compose_backup" "$COMPOSE_TARGET" || return 1
            error '����ʧ�ܣ��ѻָ�ԭ Compose�����Իָ�ԭ��������'
            if docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_PROFILE_ARGS[@]}" up -d && wait_selected_services; then
                info 'ԭ Compose ��Ӧ�ķ����ѻָ���ͨ���������'
            else
                error 'ԭ Compose �ѻָ���������ָ�δͨ������������״̬'
            fi
        else
            rm -f -- "$COMPOSE_TARGET"
            error '�״β���ʧ�ܣ��ѳ��ر��� Compose �ļ��������������Ų�'
        fi
    fi
    return 1
fi
info '��ѡ������ͨ���������'

# File Browser ���������Ա����ֻ���״γ�ʼ����־�г���һ��
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
        info "File Browser �״ι���Ա���루�û� admin�����������沢�޸ģ���"
        echo "  ${FILEBROWSER_PASSWORD_LINE}"
    else
        warn "δ����־���ҵ� File Browser �״����루�������ݿ�ʱ�����ٴ����ɣ�"
        warn "��Ϊ�״β�������: cd ${STACK_DIR} && docker compose --env-file .browserless.env logs filebrowser"
    fi
fi

echo ""
step "�������"

echo ""
info "������������ɣ�����Ϊ��ǰ״̬��"
echo ""
echo "  ������:          $(hostname)"
echo "  Docker:          $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
echo "  Compose:         $(docker compose version --short 2>/dev/null)"
echo "  �Զ���ȫ����:    $(systemctl is-active unattended-upgrades 2>/dev/null)"
echo "  journal ����:    $(grep -oP 'SystemMaxUse=\K.*' /etc/systemd/journald.conf.d/limit.conf 2>/dev/null || echo 'δ����')"
echo "  ����Ŀ¼:        ${STACK_DIR}"
echo ""

echo -e "${CYAN}====== �������� ======${NC}"
echo ""
echo "  1. Nginx Proxy Manager"
echo "     ���� http://<������IP>:81"
echo "     �״ε�¼ƾ��������þ���汾˵������¼�������޸�"
echo ""
echo "  2. ������Ĭ�϶˿ڣ�ͨ�� NPM ����������ʣ�"
echo "     Homepage:      3000    OpenList:       5244"
echo "     IT-Tools:      80      File Browser:   80"
echo "     Gitea:         3000    Uptime Kuma:    3001"
echo "     Navidrome:     4533    Beszel Hub:     8090"
echo "     Metube:        8081    Memos:          5230"
echo "     RSSHub:        1200"
echo ""
echo "  3. ghcr.io ������ȡʧ�ܣ�"
echo "     �� homepage / it-tools / metube ��ȡ��ʱ�����ֶ����� ghcr.io ����"
echo "     ������ Docker daemon �� HTTP(S) �������������ʽ���ÿ��ŵľ���ֿ��ַ"
echo "     daemon.json �� registry-mirrors �������� Docker Hub������͸������ ghcr.io"
echo ""
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
            error '�޷���ȡ���� crontab��ֹͣ�޸��Ա���ԭ������'
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
    info "�޸�ǰ�� crontab �ѱ����� $backup"
}

# ���� 1 ������ű�������0 ���Ӧ�����������У���״̬���޸Ĺ��ù���
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
        info 'sing-box ��ʱ����δ�仯������д��'
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
    [[ -f "$STACK_DIR/docker-compose.yml" && -f "$BROWSERLESS_ENV_FILE" ]] || { error 'δ�ҵ����� Compose �������ļ������ȳ�ʼ��/��װ���'; return 1; }
    if [[ $(wc -l < "$BROWSERLESS_ENV_FILE") -ne 1 ]] || ! grep -qxE 'BROWSERLESS_TOKEN=[0-9a-f]{64}' "$BROWSERLESS_ENV_FILE"; then error '���������ļ���ʽ��Ч'; return 1; fi
    unset BROWSERLESS_TOKEN
    COMPOSE_ENV_ARGS=(--env-file "$BROWSERLESS_ENV_FILE" -f "$STACK_DIR/docker-compose.yml")
}

# Compose �� JSON ���������������ж��󣻰� Service �ֶ���һ�˶���ѡ����
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
    print("�޷���������״̬ JSON",file=sys.stderr)
    sys.exit(2)
failed=False
for service in sys.argv[1:]:
    containers=[row for row in rows if row.get("Service")==service]
    if not containers:
        print(service+": ȱ������")
        failed=True
    for row in containers:
        state=row.get("State","")
        health=row.get("Health","") or ""
        ready=state=="running" and health=="healthy"
        print(service+": "+state+" / "+(health or "ȱ�ٽ�����飬δͨ�����գ��������ģʽ������������"))
        failed=failed or not ready
sys.exit(1 if failed else 0)
' "$@"
}

wait_selected_services() {
    local timeout=${1:-$SERVICE_WAIT_TIMEOUT} configured snapshot report deadline result
    local -a expected=()
    configured=$(docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_PROFILE_ARGS[@]}" config --services) || { error '�޷�������ѡ�����嵥'; return 1; }
    [[ -n "$configured" ]] || { error '��ѡ�����嵥Ϊ��'; return 1; }
    mapfile -t expected <<< "$configured"
    deadline=$((SECONDS + timeout))
    while true; do
        snapshot=$(docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_PROFILE_ARGS[@]}" ps --all --format json) || { error '��ȡ����״̬ʧ��'; return 1; }
        if report=$(check_service_snapshot "${expected[@]}" <<< "$snapshot"); then
            printf '%s\n' "$report"
            return 0
        else
            result=$?
        fi
        if (( result > 1 )); then error '����״̬�޷��������鹤�߲�����'; return 1; fi
        if (( SECONDS >= deadline )); then
            printf '%s\n' "$report" >&2
            error '��ѡ������δȫ���ﵽ running + healthy��������״̬��Ч'
            return 1
        fi
        sleep 2
    done
}

start_selected_services() {
    local update=$1
    if [[ "$update" == 1 ]]; then
        docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_PROFILE_ARGS[@]}" pull || { error '�������ʧ�ܣ�δִ������'; return 1; }
    fi
    # ��ͨ��װֻ����ȱʧ���񣻲������滻���о���
    docker compose "${COMPOSE_ENV_ARGS[@]}" "${COMPOSE_PROFILE_ARGS[@]}" up -d || { error 'Compose ����ʧ��'; return 1; }
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
            info "$service: ${state:-δ��װ}"
        done
        info "ӵ�����ƣ�$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '������������')"
        if command -v crontab >/dev/null 2>&1; then
            read_root_crontab || return 1
            if [[ -n "$(filter_sb_update_cron 1 <<< "$ROOT_CRONTAB_CONTENT")" ]]; then info 'sing-box ��ʱ���£�������'; else info 'sing-box ��ʱ���£�δ����'; fi
        fi
    fi
}

update_selected() {
    if [[ "$VPS_SCENE" == domestic ]]; then
        setup_existing_stack || return 1
        start_selected_services 1
    else
        if [[ "$INSTALL_NEXTTRACE" == 1 ]]; then
            if ! command -v nexttrace >/dev/null 2>&1 && ! command -v nxtrace >/dev/null 2>&1; then error 'NextTrace δ��װ����ʹ�������װģʽ'; return 1; fi
            run_installer https://nxtrace.org/nt || return 1
        fi
        if [[ "$INSTALL_SING_BOX" == 1 ]]; then
            [[ -x /usr/local/bin/sb ]] || { error 'δ�ҵ� sb �����ű������Ȱ�װ'; return 1; }
            update_singbox || return 1
        fi
    fi
}

# ��������װ�������������ز���� Bash �﷨������ʧ�ܲ���ִ�в������ݡ�
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
�÷���bash vps-init.sh [--plan | --help]
  --plan  ��ʾ�����ſ���ѡ�񲢴�ӡ����������װ�������޸�ϵͳ��������ͨ�û���ִ�С�
  --help  ��ʾ������
����˳�򣺱���ϵͳ�ſ� �� ѡ����� �� ѡ����; / ��· �� ѡ�񹤾� / ������ �� ��̨���� �� ִ�з�����
ϵͳ�ſ�ֻ��ȡ������Ϣ��������̽�⣻��ʽִ��ǰУ��ϵͳ�汾��root Ȩ�޼� systemd��
������VPS_MODE������ԭ��ţ���
  1) full��������ʼ�����ʺ��»������س�Ĭ��ѡ��
  2) components����װ / ����������ʺϲ�װ���ߡ�������񡢵�����̨����
  3) status���鿴����״̬��ֻ����
  4) update������������� / ���񣬸��õ�ǰ����
  0) �˳�
������VPS_SCENE����
  1) hk / jp��HK / JP ��Ʒ��·
  2) la��LA ���ӳ���·
  3) de��DE / �����˸���·
  4) minimal�����������
  5) domestic��Docker ���йܷ���ԭ���ڳ����������� VPS ����ѡ��
  0) �˳�
ֻ��������ʼ����Ӧ�ó����е�ϵͳ / TCP ���ã������������Գ���ȷ�������Χ��
���������VPS_COMPONENTS����
  1) NextTrace + sing-box��ֱ�ӻس�Ĭ��ѡ��
  2) �� NextTrace
  3) �� sing-box
  0) ��ѡ��
��̨ѡ�IPERF3_ACTION / WATCHTOWER_ACTION / SB_UPDATE_ACTION����
  1) ���ã���װģʽ�����õ�����Ĭ��ѡ��
  2) ���������ã���������ͣ��
  0) ������״����������ʱ��ʾ��Ҳ������ʽ����������
��װʱ�˵�ֻ��ʾ����ǰ������/����ģʽ����ʾ��̨�˵���ACTION Ĭ�ϱ���Ϊ 0��
Docker �����飨SERVICE_PROFILES��֧�ֶ��Ŷ�ѡ��Ҳ���ܶ�Ӧ profile ���ƣ���
  1) tools�������빤�ߣ�Homepage + IT-Tools��
  2) code�������йܣ�Gitea��
  3) media�����������أ�Navidrome + MeTube��
  4) rss��RSS ���ģ�RSSHub + Browserless + Redis��
  5) files���ļ�������File Browser + OpenList��
  6) monitoring�������أ�Uptime Kuma + Beszel��
  7) notes���ʼǱ�����Memos��
  8) all��ȫ��������
  0) none������������ NPM��Ĭ�ϣ����������֤�������
���� 1,4,6��0 �� 8 �赥��ʹ�á���̨���񵥶�ѡ��δѡ������з��񲻻ᱻж�ء�
����������VPS_HOSTNAME��UPGRADE_SYSTEM��INSTALL_STARSHIP��RESET_STARSHIP_CONFIG��
          IPERF3_PORT��HOMEPAGE_HOST��MEMOS_IMAGE��STACK_DIR��COMPOSE_PROJECT_NAME��DOCKER_MIRRORS��SERVICE_WAIT_TIMEOUT��
Docker Ĭ��Ŀ¼��/root��Compose Ϊ /root/docker-compose.yml��Ӧ�����ݾ�λ�ڸ�Ŀ¼�¡�
File Browser �̶����� /root��Redis ���������������в�������ԭ��Ŀ����ʵ�� Redis ������
��ѡ�еķ���ȫ���ﵽ running + healthy ��ͨ�����գ�Ӧ���¹��ؼ����������ѡ���ģʽ��
�ɲ�������ͣ�������ݲ�Ǩ�� Compose��������Ӧ�����ݣ��ű������Զ���Ǩ�ļ���
���Զ�����Ŀ��������ɾ����Ǩ��ʱ����ͨ�� COMPOSE_PROJECT_NAME ָ��ԭ��Ŀ����
HELP
}

main() {
    local plan_only=0
    case "${1:-}" in
        --help|-h) show_help; return 0 ;;
        --plan) plan_only=1 ;;
        '') ;;
        *) die 'δ֪������ʹ�� --help �鿴�÷�' ;;
    esac
    (( $# <= 1 )) || die '�������࣬ʹ�� --help �鿴�÷�'
    print_system_overview
    if (( plan_only == 1 )); then
        info '��ǰΪ����Ԥ����ֻ��ȡ������Ϣ�ʹ�ӡѡ�񣬲���װ�������޸�ϵͳ��'
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
        info 'û����Ҫ��װ���������������ѡ��̨�������� APT'
    fi
    if [[ "$VPS_MODE" == full ]]; then
        step '�ն�������Starship��Bash��'
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
        step '��ʼ�����'
        info "������$SCENE_NAME��ӵ�����ƣ�$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '������������')"
        info "iperf3��$(systemctl is-active iperf3-server.service 2>/dev/null || true)��fail2ban��$(systemctl is-active fail2ban 2>/dev/null || true)"
        info '����ά������������һ�Σ�reboot��Starship �������� SSH ����Ч��'
    fi
}

# ��������� source ʱֻ���غ���������ִ�У��� bash <(curl ...)���Ž��� main��
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
