#!/bin/bash
# source 仅加载函数；系统操作全部使用替身或重定向到临时目录。
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "$project_dir/tests/.unified-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1091
source "$project_dir/vps-init.sh"
read_tty() { printf -v "$1" '%s' "${3-}"; }
if ! python3 -c 'import sys' >/dev/null 2>&1; then python3() { python "$@"; }; fi
VPS_MODE=full
IPERF3_ACTION=0 WATCHTOWER_ACTION=0 SB_UPDATE_ACTION=0 SERVICE_WAIT_TIMEOUT=1

# 菜单、默认值、序号与兼容名称、非法值均在任何系统操作前处理。
for selection in 1 2 3 4 5 hk la de minimal domestic; do
    (
        VPS_SCENE=$selection
        unset VPS_COMPONENTS SERVICE_PROFILES
        select_scene
        select_components
        if [[ "$VPS_SCENE" == domestic ]]; then
            select_services
            [[ ${#SELECTED_PROFILE_NAMES[@]} == 0 ]] || fail '国内默认启动了可选服务'
            collect_homepage
        fi
        validate_options
        print_plan
    ) > "$test_dir/plan"
done
for selection in '1,4,6' 'tools,rss,monitoring' '1,1,4,6'; do
    SERVICE_PROFILES=$selection select_services > "$test_dir/plan"
    [[ "${SELECTED_PROFILE_NAMES[*]}" == 'tools rss monitoring' ]] || fail '序号或名称映射错误'
done
SERVICE_PROFILES=8 select_services > "$test_dir/plan"
[[ ${#SELECTED_PROFILE_NAMES[@]} == 7 ]] || fail '全部服务选择错误'
for selection in ',' '1,' ',1' '1,,2' 'unknown' '0,1' '8,1'; do
    if (SERVICE_PROFILES=$selection; select_services) > "$test_dir/error" 2>&1; then fail "接受无效服务: $selection"; fi
done
if (VPS_SCENE=invalid; select_scene) > "$test_dir/error" 2>&1; then fail '接受无效场景'; fi
if (unset VPS_SCENE; select_scene) > "$test_dir/error" 2>&1; then fail '无终端时擅自选择场景'; fi
if (VPS_SCENE=minimal; VPS_COMPONENTS=3; select_components) > "$test_dir/error" 2>&1; then fail '精简版安装了额外工具'; fi
if (VPS_SCENE=hk; IPERF3_PORT=80; validate_options) > "$test_dir/error" 2>&1; then fail '接受无效端口'; fi
if (VPS_SCENE=hk; UPGRADE_SYSTEM=wrong; validate_options) > "$test_dir/error" 2>&1; then fail '接受无效升级开关'; fi
printf '[PASS] 菜单、默认值、参数校验\n'

# 只运行调度函数；所有初始化函数均为记录调用的替身。
for scene in 1 2 3 4 5; do
    (
        for fn in preflight collect_hostname collect_homepage configure_hostname install_base configure_starship configure_security configure_tcp configure_iperf3 configure_fail2ban install_nexttrace install_singbox configure_sb_update install_docker deploy_services; do
            eval "$fn() { printf '%s\\n' '$fn' >> \"\$test_dir/calls\"; }"
        done
        sysctl() { printf 'mock\n'; }
        systemctl() { printf 'active\n'; }
        VPS_SCENE=$scene
        unset VPS_COMPONENTS SERVICE_PROFILES
        if [[ "$scene" == 1 ]]; then VPS_COMPONENTS=3; SB_UPDATE_ACTION=1; IPERF3_ACTION=1; fi
        : > "$test_dir/calls"
        main --plan > "$test_dir/plan"
        [[ ! -s "$test_dir/calls" ]] || fail '--plan 触发了系统步骤'
        main > "$test_dir/run"
        for fn in configure_hostname install_base configure_starship configure_security; do
            [[ $(grep -cx "$fn" "$test_dir/calls") == 1 ]] || fail "公共步骤没有恰好执行一次: $fn"
        done
        if [[ "$scene" == 5 ]]; then
            grep -qx deploy_services "$test_dir/calls" || fail '未部署国内服务'
            ! grep -qE 'configure_tcp|configure_fail2ban|install_nexttrace|install_singbox' "$test_dir/calls" || fail '国内场景调用了境外模块'
        else
            ! grep -qx install_docker "$test_dir/calls" || fail '境外场景安装了 Docker'
            grep -qx configure_tcp "$test_dir/calls" || fail '未调用 TCP 调优'
            if [[ "$scene" == 4 ]]; then
                ! grep -qE 'install_nexttrace|install_singbox|configure_sb_update' "$test_dir/calls" || fail '精简场景安装了可选工具'
            elif [[ "$scene" == 1 ]]; then
                grep -qx install_singbox "$test_dir/calls" || fail '未安装选择的 sing-box'
                grep -qx configure_sb_update "$test_dir/calls" || fail '未配置选择的自动更新'
            else
                grep -qx install_nexttrace "$test_dir/calls" || fail '未安装默认 NextTrace'
                ! grep -qx configure_sb_update "$test_dir/calls" || fail '默认配置了 sb 更新'
            fi
        fi
    )
done
printf '[PASS] 五个场景的模块调度与只读预览\n'

# TCP 函数的 /etc 路径全部替换为测试目录，sysctl/modprobe 为替身。
(
    definition=$(declare -f configure_tcp)
    definition=${definition//\/etc\//$test_dir/etc/}
    eval "$definition"
    mkdir -p "$test_dir/etc/sysctl.d"
    modprobe() { return 0; }
    modinfo() { return 1; }
    sysctl() {
        if [[ "$1" == -n ]]; then
            case "$2" in
                net.ipv4.tcp_available_congestion_control) echo 'cubic bbr' ;;
                net.ipv4.tcp_congestion_control) echo bbr ;;
                net.core.default_qdisc) [[ "$kernel_mode" != partial ]] ;;
                *) echo 1 ;;
            esac
        elif [[ "$1" == -w ]]; then
            [[ "$kernel_mode" != denied ]] || return 1
            [[ "$kernel_mode:$2" != partial:vm.swappiness=* ]] || return 1
        else
            fail '意外的 sysctl 调用'
        fi
    }
    for VPS_SCENE in hk la de minimal; do
        SCENE_NAME=$VPS_SCENE kernel_mode=normal
        printf 'old config\n' > "$test_dir/etc/sysctl.d/99-vps-tuning.conf"
        printf 'net.ipv4.tcp_rmem = 1 2 3\nnet.ipv4.ip_forward = 1\n' > "$test_dir/etc/sysctl.conf"
        configure_tcp > "$test_dir/tcp"
        config="$test_dir/etc/sysctl.d/99-vps-tuning.conf"
        case "$VPS_SCENE" in
            hk|minimal) max=16777216; wmem=65536 ;;
            la) max=33554432; wmem=65536 ;;
            de) max=33554432; wmem=16384 ;;
        esac
        grep -qx "net.ipv4.tcp_rmem = 4096 131072 $max" "$config" || fail 'TCP 接收缓冲差异丢失'
        grep -qx "net.ipv4.tcp_wmem = 4096 $wmem $max" "$config" || fail 'TCP 发送缓冲差异丢失'
        grep -qx 'net.ipv4.ip_forward = 1' "$test_dir/etc/sysctl.conf" || fail '修改了无关网络参数'
        if [[ "$VPS_SCENE" == de ]]; then grep -qx 'net.ipv4.tcp_slow_start_after_idle = 0' "$config" || fail 'DE 专用参数丢失'; fi
    done
    kernel_mode=partial
    printf 'vm.swappiness = 60\n' > "$test_dir/etc/sysctl.conf"
    configure_tcp > "$test_dir/tcp"
    ! grep -q '^vm.swappiness\|^net.core.default_qdisc' "$config" || fail '持久化了失败参数'
    grep -qx 'vm.swappiness = 60' "$test_dir/etc/sysctl.conf" || fail '接管了失败参数'
    kernel_mode=denied
    printf 'keep original\n' > "$config"
    configure_tcp > "$test_dir/tcp"
    grep -qx 'keep original' "$config" || fail '全部受限时覆盖了原配置'
)
printf '[PASS] TCP 场景差异、部分失败、全部受限及配置保留\n'

# Compose 生成在临时服务目录进行；Docker、systemctl、sleep 均为替身。
(
    STACK_DIR="$test_dir/stacks"
    SERVICE_PROFILES=4 select_services > "$test_dir/plan"
    HOMEPAGE_HOST=nav.example.com
    compose_ok=1 up_fail_once=0
    docker() {
        if [[ "$1" == --version ]]; then printf 'Docker version mock\n'; return 0; fi
        if [[ "$*" == 'compose version --short' ]]; then printf 'mock\n'; return 0; fi
        [[ "$1" == compose && "$2" == --env-file && "$3" == "$STACK_DIR/.browserless.env" ]] || fail 'Compose 未显式加载共享令牌文件'
        if [[ "$*" == *'config -q'* ]]; then
            [[ "$*" == *'--profile rss'* ]] || fail '校验未使用所选 profiles'
            [[ "$compose_ok" == 1 ]]
        elif [[ "$*" == *'config --services'* ]]; then
            printf 'nginx-proxy-manager\nrsshub\nredis\nbrowserless\n'
        elif [[ "$*" == *'ps --all --format json'* ]]; then
            printf '[{"Service":"nginx-proxy-manager","State":"running"},{"Service":"rsshub","State":"running","Health":"healthy"},{"Service":"redis","State":"running","Health":"healthy"},{"Service":"browserless","State":"running"}]\n'
        elif [[ "$*" == *'up -d'* && "$up_fail_once" == 1 ]]; then
            up_fail_once=0
            return 1
        fi
    }
    sleep() { :; }
    systemctl() { printf 'active\n'; }
    deploy_services > "$test_dir/compose"
    cp "$STACK_DIR/.browserless.env" "$test_dir/token-before"
    grep -qxE 'BROWSERLESS_TOKEN=[0-9a-f]{64}' "$test_dir/token-before" || fail '令牌生成错误'
    deploy_services > "$test_dir/compose"
    cmp -s "$STACK_DIR/.browserless.env" "$test_dir/token-before" || fail '重跑未复用令牌'
    [[ $(find "$STACK_DIR" -maxdepth 1 -name 'docker-compose.yml.bak.*' | wc -l) == 0 ]] || fail '相同 Compose 产生了备份'
    cp "$STACK_DIR/docker-compose.yml" "$test_dir/compose-before"
    if (compose_ok=0; deploy_services) > "$test_dir/error" 2>&1; then fail '无效 Compose 未停止部署'; fi
    cmp -s "$STACK_DIR/docker-compose.yml" "$test_dir/compose-before" || fail '校验失败覆盖了原 Compose'
    printf '# existing custom config\n' >> "$STACK_DIR/docker-compose.yml"
    cp "$STACK_DIR/docker-compose.yml" "$test_dir/custom-compose"
    if (up_fail_once=1; deploy_services) > "$test_dir/error" 2>&1; then fail '启动失败没有返回失败'; fi
    cmp -s "$STACK_DIR/docker-compose.yml" "$test_dir/custom-compose" || fail '启动失败未恢复原 Compose'
    grep -q '原 Compose 对应的服务已恢复' "$test_dir/error" || fail '未验证恢复原服务配置'
    printf 'invalid\n' > "$STACK_DIR/.browserless.env"
    if (deploy_services) > "$test_dir/error" 2>&1; then fail '接受畸形令牌'; fi
)
printf '[PASS] Compose 令牌复用、无变化跳过、校验/启动失败恢复及恢复服务验收\n'

# 下载失败即使写出部分脚本，也不能执行；语法错误同样必须阻止执行。
(
    installer_mode=partial
    curl() {
        printf 'printf executed > "%s/installer-executed"\n' "$test_dir" > "$4"
        case "$installer_mode" in
            partial) return 1 ;;
            invalid) printf 'if then\n' >> "$4" ;;
        esac
    }
    if run_installer https://example.com/installer.sh > "$test_dir/install" 2>&1; then fail '执行了未下载完整的安装器'; fi
    [[ ! -e "$test_dir/installer-executed" ]] || fail '下载失败仍然执行了代码'
    installer_mode=invalid
    if run_installer https://example.com/installer.sh > "$test_dir/install" 2>&1; then fail '执行了语法错误的安装器'; fi
    [[ ! -e "$test_dir/installer-executed" ]] || fail '语法错误仍然执行了代码'
    installer_mode=success
    run_installer https://example.com/installer.sh > "$test_dir/install" 2>&1
    [[ -e "$test_dir/installer-executed" ]] || fail '完整下载的测试安装器未执行'
)
printf '[PASS] 第三方安装器下载失败及语法错误拦截\n'

# 实际命令入口只运行 --plan；覆盖文件、进程替换和管道，尤其是 stdin 无 BASH_SOURCE 的情况。
VPS_SCENE=3 VPS_COMPONENTS=1 bash "$project_dir/vps-init.sh" --plan > "$test_dir/entry-file"
VPS_SCENE=3 VPS_COMPONENTS=1 bash <(cat "$project_dir/vps-init.sh") --plan > "$test_dir/entry-fd"
cat "$project_dir/vps-init.sh" | VPS_SCENE=5 VPS_COMPONENTS=0 SERVICE_PROFILES=4,6 bash -s -- --plan > "$test_dir/entry-pipe"
grep -q 'DE / 法兰克福线路' "$test_dir/entry-file" || fail '文件入口未执行预览'
cmp -s "$test_dir/entry-file" "$test_dir/entry-fd" || fail '进程替换入口输出不一致'
grep -q 'rss monitoring' "$test_dir/entry-pipe" || fail '管道入口未执行预览'
printf '[PASS] 文件、进程替换和管道的只读预览入口\n'
