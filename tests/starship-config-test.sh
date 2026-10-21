#!/bin/bash
# 仅提取并测试 Starship 函数；所有安装命令均被替身拦截。
# 不运行初始化脚本，不修改账号、系统目录或服务。
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "$project_dir/tests/.starship-test.XXXXXX")
case "$test_dir" in
    "$project_dir"/tests/.starship-test.*) ;;
    *) printf '%s\n' '测试目录不在预期范围内'; exit 1 ;;
esac
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/tmp"
export TMPDIR="$test_dir/tmp"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

getent() { printf 'root:x:0:0:root:%s:/bin/bash\n' "$fixture_home"; }
starship() {
    case "$1" in
        --version) printf 'starship test\n' ;;
        init)
            printf 'init\n' >> "$init_log"
            printf 'PS1="test> "\n'
            ;;
        *) return 1 ;;
    esac
}
curl() {
    printf 'download\n' >> "$install_log"
    [[ "$download_ok" == 1 ]] || return 1
    local destination=${@: -1}
    printf '# mock installer\n' > "$destination"
}
sh() {
    printf 'install\n' >> "$install_log"
    [[ -s "$1" && "$2" == --yes && "$3" == --bin-dir && "$4" == /usr/local/bin ]] || return 1
    [[ "$install_ok" == 1 ]]
}
install() {
    [[ "$*" == '-d -m 0755 /usr/local/bin' ]] || fail "拦截到意外 install 调用: $*"
}

for source_file in "$project_dir"/*.sh; do
    fixture_home="$test_dir/$(basename "$source_file" .sh)"
    mkdir -p "$fixture_home/.config"
    init_log="$fixture_home/init.log"
    install_log="$fixture_home/install.log"
    download_ok=1
    install_ok=1
    unset INSTALL_STARSHIP RESET_STARSHIP_CONFIG
    awk '/^# ---------- Starship 公共配置（/{inside=1} inside{print} /^# ---------- Starship 公共配置结束/{exit}' \
        "$source_file" > "$test_dir/function.sh"
    [[ -s "$test_dir/function.sh" ]] || fail "未找到 Starship 函数"
    # shellcheck disable=SC1091
    source "$test_dir/function.sh"

    printf '# existing bashrc\nPS1="old> "\n' > "$fixture_home/.bashrc"
    printf '# existing login\n' > "$fixture_home/.bash_profile"
    printf '# untouched profile\n' > "$fixture_home/.profile"
    printf '# old custom theme\n' > "$fixture_home/.config/starship.toml"
    cp "$fixture_home/.config/starship.toml" "$test_dir/custom-theme"
    configure_starship > "$test_dir/output"
    grep -q '^# existing bashrc$' "$fixture_home/.bashrc" || fail '丢失原 bashrc 内容'
    grep -q '^# existing login$' "$fixture_home/.bash_profile" || fail '丢失原登录文件内容'
    [[ $(wc -l < "$fixture_home/.profile") == 1 ]] || fail '修改了未生效的 profile'
    [[ $(grep -c '^# >>> vps-init starship >>>$' "$fixture_home/.bashrc") == 1 ]] || fail '初始化区块数量不正确'
    cmp -s "$fixture_home/.config/starship.toml" "$test_dir/custom-theme" || fail '默认覆盖了已有主题'
    [[ $(find "$fixture_home" -name '*.bak.*' | wc -l) == 2 ]] || fail '已有主题不应被改写或备份'
    cp "$fixture_home/.bashrc" "$test_dir/expected-bashrc"
    configure_starship > "$test_dir/output"
    cmp -s "$fixture_home/.bashrc" "$test_dir/expected-bashrc" || fail '重跑改变了 bashrc'
    cmp -s "$fixture_home/.config/starship.toml" "$test_dir/custom-theme" || fail '重跑覆盖了已有主题'
    [[ $(find "$fixture_home" -name '*.bak.*' | wc -l) == 2 ]] || fail '重跑产生了无意义备份'

    # 只有显式重置才替换主题，并完整备份用户原来的内容。
    RESET_STARSHIP_CONFIG=1 configure_starship > "$test_dir/output"
    grep -q '^add_newline = false$' "$fixture_home/.config/starship.toml" || fail '重置缺少空行调整'
    grep '^format = ' "$fixture_home/.config/starship.toml" | head -n 1 | grep -qv '\$line_break' || fail '重置仍包含换行模块'
    theme_backup=$(find "$fixture_home/.config" -name 'starship.toml.bak.*')
    [[ -n "$theme_backup" ]] || fail '重置没有备份原主题'
    cmp -s "$theme_backup" "$test_dir/custom-theme" || fail '主题备份与原内容不一致'
    RESET_STARSHIP_CONFIG=1 configure_starship > "$test_dir/output"
    [[ $(find "$fixture_home" -name '*.bak.*' | wc -l) == 3 ]] || fail '重复重置产生了无意义备份'

    # 同一交互式 Bash 即使重复加载登录文件和 bashrc，也只初始化一次。
    export -f starship
    export init_log
    HOME="$fixture_home" bash --noprofile --norc -i -c \
        'source "$HOME/.bash_profile"; source "$HOME/.bashrc"; source "$HOME/.bashrc"; [[ "$STARSHIP_CONFIG" == "$HOME/.config/starship.toml" ]]' \
        > "$test_dir/interactive-output" 2>&1
    [[ $(wc -l < "$init_log") == 1 ]] || fail '交互式会话重复初始化'
    HOME="$fixture_home" bash --noprofile --norc -c 'source "$HOME/.bashrc"' > "$test_dir/output"
    [[ $(wc -l < "$init_log") == 1 ]] || fail '非交互式会话加载了 Starship'

    # 默认 ~/.profile 创建、显式跳过、以及畸形配置不得覆盖原文件。
    fixture_home="$fixture_home/empty"
    mkdir -p "$fixture_home"
    INSTALL_STARSHIP=0 configure_starship > "$test_dir/output"
    [[ ! -e "$fixture_home/.bashrc" ]] || fail '跳过模式仍然创建了配置'
    configure_starship > "$test_dir/output"
    [[ -f "$fixture_home/.profile" ]] || fail '没有创建默认登录文件'
    grep -q '^add_newline = false$' "$fixture_home/.config/starship.toml" || fail '首次运行没有创建内置主题'
    grep '^format = ' "$fixture_home/.config/starship.toml" | head -n 1 | grep -qv '\$line_break' || fail '首次创建仍包含换行模块'
    printf '# >>> vps-init starship >>>\n' > "$fixture_home/.bashrc"
    cp "$fixture_home/.config/starship.toml" "$test_dir/expected-config"
    if configure_starship > "$test_dir/output" 2>&1; then
        fail '畸形标记没有导致失败'
    fi
    [[ $(wc -l < "$fixture_home/.bashrc") == 1 ]] || fail '畸形配置被覆盖'
    cmp -s "$fixture_home/.config/starship.toml" "$test_dir/expected-config" || fail '校验失败仍然写入主题'

    # 模拟尚未安装 Starship：仅改变函数内的 command -v，不进行真实安装。
    command() {
        if [[ "$*" == '-v starship' ]]; then return 1; fi
        builtin command "$@"
    }
    fixture_home="$fixture_home/download"
    mkdir -p "$fixture_home"
    download_ok=0
    configure_starship > "$test_dir/output"
    [[ ! -e "$fixture_home/.bashrc" ]] || fail '下载失败仍然改写配置'
    [[ $(grep -c '^install$' "$install_log" || true) == 0 ]] || fail '下载失败仍执行了安装程序'
    download_ok=1
    install_ok=0
    configure_starship > "$test_dir/output"
    [[ ! -e "$fixture_home/.bashrc" ]] || fail '安装失败仍然改写配置'
    install_ok=1
    configure_starship > "$test_dir/output"
    [[ -f "$fixture_home/.config/starship.toml" ]] || fail '模拟安装成功后未配置主题'
    unset -f command
    printf '[PASS] %s\n' "$(basename "$source_file")"
done
