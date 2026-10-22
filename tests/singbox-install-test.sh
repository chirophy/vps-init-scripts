#!/bin/bash
# 安装器、服务检查使用替身；内核和管理脚本只创建在项目临时目录。
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "$project_dir/tests/.singbox-test.XXXXXX")
case "$test_dir" in "$project_dir"/tests/.singbox-test.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "$test_dir"' EXIT
source "$project_dir/vps-init.sh"
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# 成功清理分支中的条件为假，后面的无参数 exit 会继承退出码 1。
cleanup_success() { :; [[ ! "$1" ]] && { exit 99; }; exit; }
cleanup_status=0
(cleanup_success ok) || cleanup_status=$?
[[ "$cleanup_status" == 1 ]] || fail '未复现上游成功清理退出码'

prepare_fixture() {
    local name=$1 definition escaped_root
    fixture="$test_dir/$name"
    mkdir -p "$fixture/usr/local/bin"
    printf -v escaped_root '%q' "$fixture"
    definition=$(declare -f probe_singbox_installation)
    definition=${definition//\/etc\/sing-box/$escaped_root/etc/sing-box}
    eval "$definition"
    definition=$(declare -f install_singbox)
    definition=${definition//\/etc\/sing-box/$escaped_root/etc/sing-box}
    definition=${definition//\/usr\/local\/bin\/sb/$escaped_root/usr/local/bin/sb}
    eval "$definition"
    # 不允许探测或执行开发机上的同名程序。
    type() {
        [[ "$*" == '-P sing-box' ]] || fail '意外的命令探测'
        if [[ -x "$fixture/usr/local/bin/sing-box" ]]; then
            printf '%s\n' "$fixture/usr/local/bin/sing-box"
        else
            return 1
        fi
    }
    systemctl() {
        [[ "$*" == 'is-active --quiet sing-box.service' ]] || fail '意外的服务操作'
        [[ "$service_active" == 1 ]]
    }
}

make_core() {
    mkdir -p "$fixture/etc/sing-box/bin" "$fixture/etc/sing-box/conf"
    cat > "$fixture/etc/sing-box/bin/sing-box" <<'CORE'
#!/bin/bash
[[ "$1" == version ]] || exit 90
printf 'sing-box version fixture\n'
CORE
    chmod +x "$fixture/etc/sing-box/bin/sing-box"
    printf 'existing config fixture\n' > "$fixture/etc/sing-box/conf/fixture.json"
}

for specification in '1 healthy 0' '0 healthy 0' '1 missing 1' '0 missing 1' '1 invalid 1' '0 invalid 1' '1 inactive 1' '0 inactive 1'; do
    (
        read -r mock_installer_status outcome expected_status <<< "$specification"
        prepare_fixture "$mock_installer_status-$outcome"
        service_active=0
        run_installer() {
            printf 'called\n' >> "$fixture/installer-calls"
            case "$outcome" in
                healthy) make_core; service_active=1 ;;
                inactive) make_core ;;
                invalid)
                    make_core
                    printf '#!/bin/bash\necho management-entry-only\n' > "$fixture/etc/sing-box/bin/sing-box"
                    ;;
                missing) ;;
            esac
            return "$mock_installer_status"
        }
        status=0
        install_singbox > "$fixture/output" 2>&1 || status=$?
        [[ "$status" == "$expected_status" ]] || fail "结果错误: $specification / $status"
        [[ $(wc -l < "$fixture/installer-calls") == 1 ]] || fail '安装器调用次数错误'
        if [[ "$expected_status" == 0 ]]; then
            grep -q 'sing-box 安装完成' "$fixture/output" || fail '成功时没有明确确认安装完成'
            ! grep -q '\[ERROR\]' "$fixture/output" || fail '实际安装成功仍然报错'
            if [[ "$mock_installer_status" == 1 ]]; then
                grep -q '实际内核和服务检查均已通过' "$fixture/output" || fail '未说明非零退出码的处理'
            fi
            install_singbox > "$fixture/repeat-output" 2>&1
            [[ $(wc -l < "$fixture/installer-calls") == 1 ]] || fail '重复运行重新安装了健康实例'
            grep -qx 'existing config fixture' "$fixture/etc/sing-box/conf/fixture.json" || fail '重复运行修改了已有节点文件'
        else
            ! grep -q 'sing-box 安装完成' "$fixture/output" || fail '实际检查失败仍宣称安装成功'
        fi
    )
done
printf '[PASS] 安装器退出码与实际结果交叉验证、真实失败拦截及健康实例重复跳过\n'

(
    prepare_fixture partial-manager
    service_active=0
    printf '#!/bin/bash\necho manager\n' > "$fixture/usr/local/bin/sb"
    chmod +x "$fixture/usr/local/bin/sb"
    run_installer() { fail '对已有残留自动执行了重装'; }
    if install_singbox > "$fixture/output" 2>&1; then fail '仅管理入口被判断为完整安装'; fi
    grep -q '未检测到可执行的 sing-box 内核' "$fixture/output" || fail '残留诊断不准确'
)
(
    prepare_fixture partial-path-manager
    service_active=1
    mkdir -p "$fixture/etc/sing-box/sh"
    printf '#!/bin/bash\necho invoked > "%s/manager-invoked"\n' "$fixture" > "$fixture/etc/sing-box/sh/sing-box.sh"
    chmod +x "$fixture/etc/sing-box/sh/sing-box.sh"
    ln -s "$fixture/etc/sing-box/sh/sing-box.sh" "$fixture/usr/local/bin/sing-box"
    # Windows Git Bash 可能把 ln -s 实现成复制；这种环境用替身模拟 Linux 的链接解析。
    if [[ ! -L "$fixture/usr/local/bin/sing-box" ]]; then
        readlink() {
            [[ "$*" == "-f -- $fixture/usr/local/bin/sing-box" ]] || fail '意外的链接解析'
            printf '%s\n' "$fixture/etc/sing-box/sh/sing-box.sh"
        }
    fi
    run_installer() { fail '对 PATH 管理入口残留自动执行了重装'; }
    if install_singbox > "$fixture/output" 2>&1; then fail 'PATH 管理入口被判断为可用内核'; fi
    [[ ! -e "$fixture/manager-invoked" ]] || fail '把管理脚本当作内核调用'
)
(
    prepare_fixture existing-inactive
    make_core
    service_active=0
    run_installer() { fail '对未运行实例自动执行了重装'; }
    if install_singbox > "$fixture/output" 2>&1; then fail '忽略了已安装服务未运行'; fi
    grep -q 'sing-box.service 未运行' "$fixture/output" || fail '没有区分服务未运行'
    grep -qx 'existing config fixture' "$fixture/etc/sing-box/conf/fixture.json" || fail '诊断修改了节点配置'
)
(
    prepare_fixture native-core
    service_active=1
    printf '#!/bin/bash\nprintf "sing-box version native-fixture\\n"\n' > "$fixture/usr/local/bin/sing-box"
    chmod +x "$fixture/usr/local/bin/sing-box"
    run_installer() { fail '重新安装了 PATH 中可用的原生内核'; }
    install_singbox > "$fixture/output" 2>&1
    grep -q '服务运行中，跳过安装' "$fixture/output" || fail '未识别 PATH 原生内核'
)
printf '[PASS] 管理入口残留、服务未运行、PATH 原生内核与已有配置保护\n'
