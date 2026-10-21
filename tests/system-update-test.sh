#!/bin/bash
# 只提取系统更新片段；APT 命令使用替身，不执行真实更新或安装。
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "$project_dir/tests/.update-test.XXXXXX")
case "$test_dir" in
    "$project_dir"/tests/.update-test.*) ;;
    *) printf '%s\n' '测试目录不在预期范围内'; exit 1 ;;
esac
trap 'rm -rf -- "$test_dir"' EXIT
apt_log="$test_dir/apt.log"
export apt_log

info() { printf '[INFO] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*"; }
apt-get() {
    printf '%s\n' "$*" >> "$apt_log"
    case "$1" in
        update) return "$update_status" ;;
        upgrade) return "$upgrade_status" ;;
        install) return 0 ;;
        *) return 99 ;;
    esac
}
export -f info error apt-get
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

run_case() {
    local selection=$1 expect_status=$2 expected_steps=$3 actual_status=0
    : > "$apt_log"
    (
        unset UPGRADE_SYSTEM
        if [[ "$selection" != default ]]; then
            export UPGRADE_SYSTEM="$selection"
        fi
        bash "$test_dir/fragment.sh"
    ) > "$test_dir/output" 2>&1 || actual_status=$?
    [[ "$actual_status" == "$expect_status" ]] || fail "返回值错误: $selection / $actual_status"
    local steps
    steps=$(awk '{print $1}' "$apt_log" | paste -sd, -)
    [[ "$steps" == "$expected_steps" ]] || fail "APT 调用顺序错误: $selection / $steps"
}

for source_file in "$project_dir"/*.sh; do
    printf 'set -euo pipefail\n' > "$test_dir/fragment.sh"
    # 包含紧随更新片段的实际基础工具安装命令，验证失败时不会执行它。
    awk '
        /^# ---------- 更新软件包索引与系统升级 ----------$/ {inside=1}
        inside {print}
        /^# ---------- 系统升级处理结束 ----------$/ {getline; print; exit}
    ' "$source_file" >> "$test_dir/fragment.sh"
    grep -q '^if ! apt-get update; then$' "$test_dir/fragment.sh" || fail '未找到更新逻辑'
    grep -q '^apt-get install -y ' "$test_dir/fragment.sh" || fail '未找到实际基础工具安装命令'

    export update_status=1 upgrade_status=0
    run_case default 1 update
    run_case 0 1 update
    export update_status=0 upgrade_status=1
    run_case default 1 update,upgrade
    run_case 0 0 update,install
    export update_status=0 upgrade_status=0
    run_case default 0 update,upgrade,install
    run_case 1 0 update,upgrade,install
    run_case invalid 1 ''
    printf '[PASS] %s\n' "$(basename "$source_file")"
done
