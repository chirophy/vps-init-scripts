#!/bin/bash
# 系统服务和包管理使用替身，文件事务只操作项目临时目录。
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "$project_dir/tests/.reliability-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
source "$project_dir/vps-init.sh"
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
if ! python3 -c 'import sys' >/dev/null 2>&1; then python3() { python "$@" | sed 's/\r$//'; }; fi
read_tty() { printf -v "$1" '%s' "${3-}"; }

# 多文件校验失败不重启；启动失败恢复旧配置并验证恢复后的服务。
(
    mkdir -p "$test_dir/txn"
    target_a="$test_dir/txn/a" target_b="$test_dir/txn/b"
    printf 'old-a\n' > "$target_a"; printf 'old-b\n' > "$target_b"
    : > "$test_dir/service-calls"
    systemctl() {
        printf '%s\n' "$*" >> "$test_dir/service-calls"
        case "$1" in
            is-active|is-enabled) return 0 ;;
            restart) [[ $(cat "$target_a") != start-fail ]] ;;
        esac
    }
    validator_ok() { return 0; }
    validator_bad() { return 1; }
    make_candidates() { printf '%s\n' "$1" > "$test_dir/txn/ca"; printf 'new-b\n' > "$test_dir/txn/cb"; }
    make_candidates bad
    if apply_service_files example validator_bad 1 "$test_dir/txn/ca" "$target_a" "$test_dir/txn/cb" "$target_b" > "$test_dir/output"; then fail '校验失败没有返回失败'; fi
    [[ $(cat "$target_a") == old-a && $(cat "$target_b") == old-b ]] || fail '校验失败未恢复多个文件'
    ! grep -q '^restart' "$test_dir/service-calls" || fail '校验失败仍然重启服务'
    make_candidates start-fail
    if apply_service_files example validator_ok 1 "$test_dir/txn/ca" "$target_a" "$test_dir/txn/cb" "$target_b" > "$test_dir/output"; then fail '重启失败没有返回失败'; fi
    [[ $(cat "$target_a") == old-a && $(cat "$target_b") == old-b ]] || fail '重启失败未恢复多个文件'
    [[ $(grep -c '^restart example$' "$test_dir/service-calls") == 2 ]] || fail '没有尝试恢复原服务'
    cp "$target_a" "$test_dir/txn/ca"; cp "$target_b" "$test_dir/txn/cb"
    before=$(find "$test_dir/txn" -name '*.bak.*' | wc -l)
    : > "$test_dir/service-calls"
    apply_service_files example validator_ok 1 "$test_dir/txn/ca" "$target_a" "$test_dir/txn/cb" "$target_b" > "$test_dir/output"
    [[ $(find "$test_dir/txn" -name '*.bak.*' | wc -l) == "$before" ]] || fail '未改变配置仍然备份'
    ! grep -q '^restart' "$test_dir/service-calls" || fail '未改变配置仍然重启'
    printf 'new\n' > "$test_dir/txn/ca"
    if apply_service_files example validator_bad 1 "$test_dir/txn/ca" "$test_dir/txn/new-file" > "$test_dir/output"; then fail '新文件校验失败没有返回失败'; fi
    [[ ! -e "$test_dir/txn/new-file" ]] || fail '没有撤回首次创建的失败配置'
)
printf '[PASS] 多文件校验/启动失败恢复、无变化跳过、新文件撤回\n'

# 自动更新保留已有策略；journald 内容相同时不重启或重复备份。
(
    definition=$(declare -f configure_security)
    definition=${definition//\/etc\//$test_dir/policy/etc/}
    eval "$definition"
    mkdir -p "$test_dir/policy/etc/apt/apt.conf.d"
    apt_dir="$test_dir/policy/etc/apt/apt.conf.d"
    printf 'APT::Periodic::Unattended-Upgrade "0";\n' > "$apt_dir/20auto-upgrades"
    printf 'custom security origins and reboot policy\n' > "$apt_dir/50unattended-upgrades"
    cp "$apt_dir/20auto-upgrades" "$test_dir/expected-periodic"
    cp "$apt_dir/50unattended-upgrades" "$test_dir/expected-origins"
    systemctl() { printf '%s\n' "$*" >> "$test_dir/policy-calls"; return 0; }
    apt-config() { return 0; }
    configure_security > "$test_dir/output"
    : > "$test_dir/policy-calls"
    configure_security > "$test_dir/output"
    cmp -s "$apt_dir/20auto-upgrades" "$test_dir/expected-periodic" || fail '覆盖了已有更新周期'
    cmp -s "$apt_dir/50unattended-upgrades" "$test_dir/expected-origins" || fail '覆盖了已有更新来源/重启策略'
    [[ ! -e "$apt_dir/20vps-auto-upgrades" ]] || fail '存在更新周期时仍强制写入新策略'
    ! grep -q '^restart' "$test_dir/policy-calls" || fail '无变化仍重启安全更新/日志服务'
)
printf '[PASS] 保留已有自动更新策略及安全配置重复运行\n'

# 健康状态使用真实 JSON 解析器，覆盖缺失、异常、无健康检查与多副本。
# scratch 镜像只验收运行状态，但不能忽略缺失、退出或显式 unhealthy。
printf '%s' '[{"Service":"hbbs","State":"running"},{"Service":"hbbr","State":"running"}]' | check_service_snapshot hbbs hbbr > "$test_dir/output"
for snapshot in '[]' '[{"Service":"hbbs","State":"exited"}]' '[{"Service":"hbbs","State":"running","Health":"unhealthy"}]' '[{"Service":"hbbs","State":"running","Health":"starting"}]'; do
    if check_service_snapshot hbbs <<< "$snapshot" > "$test_dir/output"; then fail 'RustDesk 异常状态被接受'; fi
done
snapshot_ok='[{"Service":"web","State":"running","Health":"healthy"},{"Service":"db","State":"running","Health":"healthy"}]'
check_service_snapshot web db <<< "$snapshot_ok" > "$test_dir/output"
for snapshot in '[]' 'invalid' '[{"Service":"web","State":"exited"}]' '[{"Service":"web","State":"running"}]' '[{"Service":"web","State":"running","Health":"unhealthy"}]' '[{"Service":"web","State":"running","Health":"starting"}]' '[{"Service":"web","State":"running","Health":"healthy"},{"Service":"web","State":"exited"}]'; do
    if check_service_snapshot web <<< "$snapshot" > "$test_dir/output" 2>&1; then fail '接受缺失、异常或无效状态'; fi
done
printf '%s\n%s\n' '{"Service":"web","State":"running","Health":"healthy"}' '{"Service":"db","State":"running","Health":"healthy"}' | check_service_snapshot web db > "$test_dir/output"
(
    COMPOSE_ENV_ARGS=() COMPOSE_PROFILE_ARGS=() SERVICE_WAIT_TIMEOUT=1
    resolve_selected_services() { SELECTED_SERVICES=(web db); }
    docker() {
        if [[ "$*" == *'config --services'* ]]; then printf 'web\ndb\n'; else printf '%s\n' "$snapshot_ok"; fi
    }
    wait_selected_services 0 > "$test_dir/output"
    snapshot_ok='[{"Service":"web","State":"running","Health":"unhealthy"}]'
    if wait_selected_services 0 > "$test_dir/output" 2>&1; then fail '启动验收忽略缺失和 unhealthy'; fi
    resolve_selected_services() { SELECTED_SERVICES=(web); }
    : > "$test_dir/polls"
    docker() {
        if [[ "$*" == *'config --services'* ]]; then
            printf 'web\n'
        else
            echo poll >> "$test_dir/polls"
            if [[ $(wc -l < "$test_dir/polls") == 1 ]]; then
                printf '{"Service":"web","State":"running","Health":"starting"}\n'
            else
                printf '{"Service":"web","State":"running","Health":"healthy"}\n'
            fi
        fi
    }
    sleep() { :; }
    wait_selected_services 5 > "$test_dir/output"
    [[ $(wc -l < "$test_dir/polls") == 2 ]] || fail '没有等待服务从 starting 转为 healthy'
)
printf '[PASS] 逐个服务、健康状态、多副本、JSON 格式与失败退出\n'

# 全部模式都只运行调度，任何系统函数均已替换。
for mode in full components status update; do
    for scene in hk domestic; do
        (
            for fn in preflight collect_hostname collect_homepage configure_hostname install_base configure_starship configure_security configure_tcp configure_fail2ban install_nexttrace install_singbox apply_background_actions install_docker deploy_services show_status update_selected; do
                eval "$fn() { printf '%s\\n' '$fn' >> \"\$test_dir/mode-calls\"; }"
            done
            sysctl() { echo mock; }; systemctl() { echo active; }
            VPS_MODE=$mode VPS_SCENE=$scene VPS_COMPONENTS=0 SERVICE_PROFILES=0
            IPERF3_ACTION=0 SB_UPDATE_ACTION=0 WATCHTOWER_ACTION=0
            : > "$test_dir/mode-calls"
            main > "$test_dir/output"
            case "$mode" in
                full) grep -qx configure_security "$test_dir/mode-calls" || fail '完整模式漏掉公共配置' ;;
                components)
                    ! grep -qE '^configure_(hostname|security|tcp|fail2ban)$|^configure_starship$' "$test_dir/mode-calls" || fail '组件模式触碰系统基础配置'
                    [[ "$UPGRADE_SYSTEM" == 0 ]] || fail '组件模式执行系统升级'
                    if [[ "$scene" == hk ]]; then ! grep -qx install_base "$test_dir/mode-calls" || fail '纯保持现状仍调用 APT'; fi
                    ;;
                status|update)
                    [[ $(wc -l < "$test_dir/mode-calls") == 2 ]] || fail '状态/更新模式执行了额外初始化'
                    if [[ "$mode" == status ]]; then grep -qx show_status "$test_dir/mode-calls"; else grep -qx update_selected "$test_dir/mode-calls"; fi
                    ;;
            esac
        )
    done
done
printf '[PASS] 四种模式的边界及组件模式禁止系统升级\n'

(
    VPS_MODE=full VPS_SCENE=hk INSTALL_SING_BOX=1
    unset IPERF3_ACTION SB_UPDATE_ACTION WATCHTOWER_ACTION
    probe_background_state() { BACKGROUND_PRESENT=0; BACKGROUND_STATE='未配置'; }
    sb_update_supported() { return 0; }
    select_background_actions > "$test_dir/background-menu"
    [[ "$IPERF3_ACTION:$SB_UPDATE_ACTION:$WATCHTOWER_ACTION" == 1:1:0 ]] || fail '适用的后台任务没有默认启用'
    ! grep -q '0) 保持现状' "$test_dir/background-menu" || fail '未配置任务仍显示保持现状'
    [[ $(sed -n 's/^[[:space:]]*\([0-9]\)).*/\1/p' "$test_dir/background-menu" | paste -sd, -) == 1,2,1,2 ]] || fail '新装菜单不是启用/不启用两项'
    configure_iperf3() { echo iperf >> "$test_dir/background"; }
    configure_sb_update() { echo sb >> "$test_dir/background"; }
    systemctl() { echo "$*" >> "$test_dir/background"; }
    crontab() { echo unused; }
    set_sb_update_cron() { echo "cron-$1" >> "$test_dir/background"; }
    : > "$test_dir/background"
    apply_background_actions
    grep -qx iperf "$test_dir/background" && grep -qx sb "$test_dir/background" || fail '默认选项没有配置后台任务'
    : > "$test_dir/background"
    IPERF3_ACTION=0 SB_UPDATE_ACTION=0
    apply_background_actions
    [[ ! -s "$test_dir/background" ]] || fail '显式保持现状仍修改了后台任务'
    IPERF3_ACTION=2 SB_UPDATE_ACTION=2
    apply_background_actions
    grep -qx 'disable --now iperf3-server.service' "$test_dir/background" || fail 'iperf3 无法独立停用'
    grep -qx cron-0 "$test_dir/background" || fail '定时更新无法独立停用'
    VPS_SCENE=domestic SERVICE_PROFILES=0
    unset WATCHTOWER_ACTION
    select_background_actions > "$test_dir/background-menu"
    [[ "$WATCHTOWER_ACTION" == 0 ]] || fail 'Watchtower 不应默认启用'
    WATCHTOWER_ACTION=1
    select_services > "$test_dir/output"
    [[ "${COMPOSE_PROFILE_ARGS[*]}" == '--profile npm --profile watchtower' ]] || fail 'Watchtower 没有独立选择'
    WATCHTOWER_ACTION=0 select_services > "$test_dir/output"
    [[ "${COMPOSE_PROFILE_ARGS[*]}" == '--profile npm' ]] || fail '显式保持现状仍新增 Watchtower profile'
    probe_background_state() { BACKGROUND_PRESENT=1; BACKGROUND_STATE='运行中'; }
    unset WATCHTOWER_ACTION
    select_background_actions > "$test_dir/background-menu"
    grep -q '当前状态：运行中' "$test_dir/background-menu" || fail '没有显示已有任务的状态'
    grep -q '0) 保持现状' "$test_dir/background-menu" || fail '已有任务不能保持现状'
    [[ "$WATCHTOWER_ACTION" == 0 ]] || fail '已有 Watchtower 默认应保持现状'
)
printf '[PASS] 后台任务默认启用、首次/已有菜单、显式保持及独立启停\n'

(
    unit_present=0 unit_active=active unit_enabled=enabled watch_present=0 watch_state=running
    cron_content_fixture=''
    systemctl() {
        case "$*" in
            'cat iperf3-server.service') [[ "$unit_present" == 1 ]] ;;
            'is-active iperf3-server.service') printf '%s\n' "$unit_active" ;;
            'is-enabled iperf3-server.service') printf '%s\n' "$unit_enabled" ;;
            *) fail '意外的服务探测' ;;
        esac
    }
    crontab() { [[ "$1" == -l ]] || fail '状态检测修改了 cron'; printf '%s\n' "$cron_content_fixture"; }
    docker() { [[ "$*" == "inspect --format {{.State.Status}} watchtower" ]] || fail '意外的 Docker 操作'; [[ "$watch_present" == 1 ]] || return 1; printf '%s\n' "$watch_state"; }
    probe_background_state IPERF3_ACTION
    [[ "$BACKGROUND_PRESENT" == 0 ]] || fail '不存在的 iperf3 被识别为已有任务'
    unit_present=1
    probe_background_state IPERF3_ACTION
    [[ "$BACKGROUND_PRESENT:$BACKGROUND_STATE" == '1:运行中，已设置开机启动' ]] || fail 'iperf3 运行状态识别错误'
    unit_active=inactive unit_enabled=disabled
    probe_background_state IPERF3_ACTION
    [[ "$BACKGROUND_STATE" == '未运行，未设置开机启动' ]] || fail 'iperf3 停用状态识别错误'
    cron_content_fixture='0 4 * * * /usr/local/bin/sb-auto-update.sh'
    probe_background_state SB_UPDATE_ACTION
    [[ "$BACKGROUND_PRESENT:$BACKGROUND_STATE" == '1:已配置定时更新' ]] || fail '未识别已有定时更新'
    probe_background_state WATCHTOWER_ACTION
    [[ "$BACKGROUND_PRESENT" == 0 ]] || fail '不存在的 Watchtower 被识别为已有任务'
    watch_present=1
    probe_background_state WATCHTOWER_ACTION
    [[ "$BACKGROUND_PRESENT:$BACKGROUND_STATE" == '1:运行中' ]] || fail 'Watchtower 运行状态识别错误'
    watch_state=exited
    probe_background_state WATCHTOWER_ACTION
    [[ "$BACKGROUND_STATE" == '已配置，未运行' ]] || fail 'Watchtower 停止状态识别错误'
)
(
    definition=$(declare -f sb_update_supported)
    printf -v fixture_manager '%q' "$test_dir/sb-manager"
    definition=${definition//\/usr\/local\/bin\/sb/$fixture_manager}
    eval "$definition"
    core_healthy=0
    probe_singbox_installation() { [[ "$core_healthy" == 1 ]]; }
    INSTALL_SING_BOX=0
    if sb_update_supported; then fail '未选择 sing-box 仍默认配置定时更新'; fi
    INSTALL_SING_BOX=1
    sb_update_supported || fail '新装 sing-box 没有提供默认启用选项'
    core_healthy=1
    if sb_update_supported; then fail '原生内核缺少管理器仍提供定时更新'; fi
    : > "$test_dir/sb-manager"
    sb_update_supported || fail '没有识别已有 sb 管理入口'
)
printf '[PASS] 已有任务只读探测及 sing-box 更新选项适用条件\n'

(
    VPS_MODE=full VPS_SCENE=hk INSTALL_SING_BOX=0
    sb_update_supported() { return 1; }
    probe_background_state() { BACKGROUND_PRESENT=0; BACKGROUND_STATE='未配置'; }
    unset IPERF3_ACTION SB_UPDATE_ACTION WATCHTOWER_ACTION
    select_background_actions > "$test_dir/background-menu"
    [[ "$IPERF3_ACTION:$SB_UPDATE_ACTION" == 1:0 ]] || fail '不适用的 sing-box 定时更新仍默认启用'
    ! grep -q '^sing-box 定时更新：' "$test_dir/background-menu" || fail '不适用时仍显示定时更新菜单'
    if (SB_UPDATE_ACTION=1; select_background_actions) > "$test_dir/output" 2>&1; then fail '接受了不适用的定时更新启用请求'; fi
    VPS_MODE=status
    probe_background_state() { fail '检查模式探测并选择后台启停选项'; }
    unset IPERF3_ACTION SB_UPDATE_ACTION WATCHTOWER_ACTION
    select_background_actions > "$test_dir/background-menu"
    [[ "$IPERF3_ACTION:$SB_UPDATE_ACTION:$WATCHTOWER_ACTION" == 0:0:0 ]] || fail '检查模式默认修改后台任务'
    [[ ! -s "$test_dir/background-menu" ]] || fail '检查模式显示了启停菜单'
)
printf '[PASS] 不适用的更新任务跳过、显式错误请求拦截及只读模式保持\n'

# cron 修改保留其他条目和注释，内容不变时不写入。
(
    definition=$(declare -f backup_root_crontab)
    definition=${definition//\/var\/backups\/vps-init/$test_dir/cron-backups}
    eval "$definition"
    # Git Bash 的 NTFS 临时目录不支持 install -m 0700；只替换此目录创建操作。
    if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
        install() {
            if [[ "$#" == 4 && "$1 $2 $3" == '-d -m 0700' ]]; then mkdir -p -- "$4"; else command install "$@"; fi
        }
    fi
    cron_file="$test_dir/crontab"
    printf '# /usr/local/bin/sb-auto-update.sh reference\n0 1 * * * /other/backup.sh\n' > "$cron_file"
    crontab() {
        if [[ "$1" == -l ]]; then cat "$cron_file"; else cat > "$cron_file"; echo write >> "$test_dir/cron-writes"; fi
    }
    set_sb_update_cron 1 > "$test_dir/output"
    set_sb_update_cron 1 > "$test_dir/output"
    [[ $(wc -l < "$test_dir/cron-writes") == 1 ]] || fail '重复启用仍写入 cron'
    set_sb_update_cron 0 > "$test_dir/output"
    [[ $(wc -l < "$cron_file") == 2 ]] || fail '停用时误删其他条目或注释'
    [[ $(find "$test_dir/cron-backups" -type f | wc -l) == 2 ]] || fail '未在隔离目录备份每次实际修改'
)
printf '[PASS] cron 精确修改与重复启用不写入\n'
