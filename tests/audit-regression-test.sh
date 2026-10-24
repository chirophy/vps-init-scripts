#!/bin/bash
# 审计回归：只在临时目录写文件，所有包管理、服务与 Docker 操作均使用替身。
# 替身和场景变量通过 source/eval 加载的被测函数间接调用。
# shellcheck disable=SC2034,SC2329
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
# shellcheck disable=SC1091
source "$project_dir/vps-init.sh"
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
sleep() { :; }
read_tty() { printf -v "$1" '%s' "${3-}"; }

# 完整主机名长度与 hosts 地址边界；不会执行 hostnamectl 或写入真实 /etc。
(
    name=$(printf 'a%.0s' {1..63}).b
    if valid_hostname "$name"; then fail '接受了 65 字符主机名'; fi
    is_valid_domain "$name" || fail '误把系统主机名限制应用到普通域名'
    definition=$(declare -f configure_hostname)
    definition=${definition//\/etc\//$test_dir/etc/}
    eval "$definition"
    mkdir -p "$test_dir/etc"
    printf '127.0.0.1 localhost\n127.0.1.10 keep-me\n127.0.1.100 keep-too\n' > "$test_dir/etc/hosts"
    hostname() { echo node.example; }
    hostnamectl() { fail '不应调用主机名修改'; }
    NEW_HOSTNAME=node.example
    configure_hostname >/dev/null
    grep -qx '127.0.1.10 keep-me' "$test_dir/etc/hosts" || fail '破坏相似 IP'
    grep -qx '127.0.1.100 keep-too' "$test_dir/etc/hosts" || fail '破坏相似 IP'
    [[ $(awk '$1=="127.0.1.1" {n++} END {print n+0}' "$test_dir/etc/hosts") == 1 ]] || fail '未追加准确主机名记录'
)
printf '[PASS] 主机名长度、域名长度及 hosts 精确匹配\n'

for failure in mktemp cp; do
    (
        mkdir -p "$test_dir/txn-$failure"
        folder="$test_dir/txn-$failure"
        printf old-a > "$folder/a"; printf old-b > "$folder/b"
        printf new-a > "$folder/ca"; printf new-b > "$folder/cb"
        systemctl() { return 0; }
        mktemp() { if [[ "$failure" == mktemp && "$*" == *'/b.bak.'* ]]; then return 1; fi; command mktemp "$@"; }
        cp() { if [[ "$failure" == cp && "$*" == *'/b.bak.'* ]]; then return 1; fi; command cp "$@"; }
        if apply_service_files fixture validate_none 0 "$folder/ca" "$folder/a" "$folder/cb" "$folder/b"; then fail '备份失败被忽略'; fi
        [[ $(cat "$folder/a") == old-a && $(cat "$folder/b") == old-b ]] || fail '备份失败留下部分新配置'
    )
done
(
    printf old > "$test_dir/enable-target"; printf new > "$test_dir/enable-candidate"
    systemctl() { case "$1" in is-enabled|enable) return 1;; *) return 0;; esac; }
    if apply_service_files fixture validate_none 1 "$test_dir/enable-candidate" "$test_dir/enable-target"; then fail 'enable 失败未传播'; fi
    [[ $(cat "$test_dir/enable-target") == old ]] || fail 'enable 失败未回滚'
)
printf '[PASS] 第二份备份创建/复制失败及 enable 失败回滚\n'

(
    mode=read-error
    backup_root_crontab() { printf '%s\n' "$1" > "$test_dir/cron-backup"; }
    crontab() {
        if [[ "$1" == -l ]]; then
            case "$mode" in
                read-error) echo 'permission denied' >&2; return 1;;
                absent) echo 'no crontab for root' >&2; return 1;;
                normal) cat "$test_dir/cron";;
            esac
        else cat > "$test_dir/cron"; touch "$test_dir/cron-written"; fi
    }
    if set_sb_update_cron 1 > "$test_dir/output"; then fail '忽略 cron 读取错误'; fi
    [[ ! -e "$test_dir/cron-written" ]] || fail '读取错误后仍覆盖 cron'
    mode=absent; set_sb_update_cron 1 >/dev/null
    grep -qx '0 4 \* \* \* /usr/local/bin/sb-auto-update.sh' "$test_dir/cron" || fail '没有创建首次 cron'
    mode=normal
    printf '0 1 * * * /opt/backup /usr/local/bin/sb-auto-update.sh\n# keep comment\n@daily /usr/local/bin/sb-auto-update.sh\n' >> "$test_dir/cron"
    cp "$test_dir/cron" "$test_dir/expected-backup"
    set_sb_update_cron 0 >/dev/null
    cmp -s "$test_dir/expected-backup" "$test_dir/cron-backup" || fail '未备份完整原任务'
    grep -qx '0 1 \* \* \* /opt/backup /usr/local/bin/sb-auto-update.sh' "$test_dir/cron" || fail '删除了把更新脚本作为参数的其他任务'
    [[ $(wc -l < "$test_dir/cron") -eq 2 ]] || fail '未精准清除本脚本任务'
    [[ -z "$(filter_sb_update_cron 1 < "$test_dir/cron")" ]] || fail '状态检测误认其他命令参数'
    printf 'EXAMPLE="a b c d e /usr/local/bin/sb-auto-update.sh end"\n' | filter_sb_update_cron 0 | grep -q EXAMPLE || fail '误删包含路径的环境变量'
)
printf '[PASS] cron 读取错误保护、首次配置、备份及无关参数保留\n'

for failure in write start enable cron; do
    (
        mkdir -p "$test_dir/sb-$failure"
        bin="$test_dir/sb-$failure"
        printf '#!/bin/bash\nexit 0\n' > "$bin/sb"; chmod +x "$bin/sb"
        definition=$(declare -f configure_sb_update)
        definition=${definition//\/usr\/local\/bin/$bin}
        eval "$definition"
        install_file_if_changed() { [[ "$failure" != write ]]; }
        set_sb_update_cron() { [[ "$failure" != cron ]]; }
        systemctl() {
            case "$1" in
                is-active) [[ "$failure" != start ]];;
                is-enabled) [[ "$failure" != enable ]];;
                start) [[ "$failure" != start ]];;
                enable) [[ "$failure" != enable ]];;
            esac
        }
        if configure_sb_update > "$test_dir/output"; then fail "定时更新 $failure 失败未传播"; fi
        ! grep -q '已部署' "$test_dir/output" || fail '错误报告部署成功'
    )
done
printf '[PASS] 定时更新写入、cron 服务启动/enable、任务写入失败传播\n'

(
    mkdir -p "$test_dir/lock"
    definition=$(declare -f acquire_sb_update_lock)
    definition=${definition//\/run\/lock/$test_dir/lock}
    eval "$definition"
    for code in 0 75 70 127; do
        flock() { return "$code"; }
        status=0; acquire_sb_update_lock > "$test_dir/output" || status=$?
        if [[ "$code" == 0 || "$code" == 75 ]]; then fixture_expected=$code; else fixture_expected=1; fi
        [[ "$status" == "$fixture_expected" ]] || fail '锁错误和争锁没有正确区分'
    done
    mkdir -p "$test_dir/update-bin"; touch "$test_dir/update-bin/sb"; chmod +x "$test_dir/update-bin/sb"
    definition=$(declare -f singbox_update_commands)
    definition=${definition//\/usr\/local\/bin/$test_dir/update-bin}
    eval "$definition"
    timeout() { printf '%s\n' "$*" >> "$test_dir/update-commands"; }
    probe_singbox_installation() { return 1; }
    if singbox_update_commands > "$test_dir/output"; then fail '更新后的不健康状态未阻止成功'; fi
    grep -q -- '--kill-after=30s 900 .* update core' "$test_dir/update-commands" || fail '更新命令没有超时'
)
printf '[PASS] 更新锁争用/错误区分、命令超时及更新后健康检查\n'

# 实际生成并在隔离路径执行 cron 脚本，验证序列化函数、日志和锁的调用顺序。
(
    mkdir -p "$test_dir/generated/bin" "$test_dir/generated/lock" "$test_dir/generated/log" "$test_dir/generated/etc/sing-box/bin"
    printf '#!/bin/bash\nexit 0\n' > "$test_dir/generated/bin/sb"
    printf '#!/bin/bash\necho "sing-box version fixture"\n' > "$test_dir/generated/etc/sing-box/bin/sing-box"
    chmod +x "$test_dir/generated/bin/sb" "$test_dir/generated/etc/sing-box/bin/sing-box"
    definition=$(declare -f configure_sb_update)
    definition=${definition//\/usr\/local\/bin/$test_dir/generated/bin}
    eval "$definition"
    systemctl() { [[ "${fixture_service_active:-1}" == 1 ]]; }
    set_sb_update_cron() { :; }
    configure_sb_update > "$test_dir/output"
    generated="$test_dir/generated/bin/sb-auto-update.sh"
    python3 - "$generated" "$test_dir/generated" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);root=sys.argv[2]
s=p.read_text().replace('/usr/local/bin',root+'/bin').replace('/run/lock',root+'/lock').replace('/var/log',root+'/log').replace('/etc/sing-box',root+'/etc/sing-box')
p.write_text(s)
PY
    flock() { return "${fixture_lock_status:-0}"; }
    timeout() { while [[ "$1" == --* ]]; do shift; done; shift; "$@"; }
    command() { if [[ "$*" == '-v caddy' ]]; then return 1; fi; builtin command "$@"; }
    export -f systemctl flock timeout command sleep
    bash "$generated"
    grep -q '更新完成' "$test_dir/generated/log/sb-update.log" || fail '生成的更新器没有成功执行'
    cp "$test_dir/generated/log/sb-update.log" "$test_dir/log-before-lock"
    fixture_lock_status=75 bash "$generated" > "$test_dir/output"
    cmp -s "$test_dir/log-before-lock" "$test_dir/generated/log/sb-update.log" || fail '争锁失败仍修改日志'
    if fixture_lock_status=70 bash "$generated" > "$test_dir/output" 2>&1; then fail '生成的更新器吞掉锁错误'; fi
    # 移走日志避免依赖 macOS/BSD stat；检验更新后服务不健康的真实生成脚本路径。
    rm "$test_dir/generated/log/sb-update.log"
    if fixture_service_active=0 bash "$generated"; then fail '生成的更新器接受更新后服务未运行'; fi
)
printf '[PASS] 生成的定时更新器实际隔离执行与日志锁顺序\n'

(
    fixture_maximum=1.53 fixture_minimum=1.44
    docker() {
        case "$*" in
            'version --format {{.Server.APIVersion}}') echo "$fixture_maximum";;
            'version --format {{.Server.MinAPIVersion}}') echo "$fixture_minimum";;
            version) [[ "$DOCKER_API_VERSION" == 1.44 || "$DOCKER_API_VERSION" == 1.43 ]];;
            *) fail '意外 Docker 命令';;
        esac
    }
    [[ $(watchtower_api_version) == 1.44 ]] || fail 'Docker 29 没有使用可接受 API'
    fixture_maximum=1.43 fixture_minimum=1.12
    [[ $(watchtower_api_version) == 1.43 ]] || fail '旧 Docker API 没有下调'
    fixture_minimum=1.45
    if watchtower_api_version > "$test_dir/output" 2>&1; then fail '接受了未兼容的未来最低 API'; fi
)
(
    installed=0
    docker() { [[ "$installed" == 1 ]]; }
    apt-cache() { echo '  Candidate: 5.6.1'; }
    apt-get() { [[ "$*" == *docker-compose-plugin* ]] || fail '安装了非 Compose 包'; installed=1; }
    ensure_compose_plugin || fail '未补装缺失 Compose'
    installed=0
    apt-cache() { echo '  Candidate: (none)'; }
    if ensure_compose_plugin > "$test_dir/output"; then fail '未识别源中没有 Compose 包'; fi
)
printf '[PASS] Watchtower API 兼容范围及独立补装 Compose\n'

(
    STACK_DIR="$test_dir/filebrowser"; declare -A ENABLED_PROFILES=([files]=1)
    install() { printf '%s\n' "$*" >> "$test_dir/ownership"; mkdir -p "${@: -1}"; }
    # find 自身也已替换，不会通过 find -exec 调用此 Shell 替身。
    # shellcheck disable=SC2032
    chown() { printf '%s\n' "$*" >> "$test_dir/ownership"; }
    find() { [[ "$*" == *'--no-dereference 1000:1000'* ]] || fail '未修复应用数据所有权'; }
    prepare_filebrowser_storage
    [[ -d "$STACK_DIR/Filebrowser/files" ]] || fail '未准备专用文件目录'
    grep -q -- '-o 1000 -g 1000' "$test_dir/ownership" || fail '首次目录所有权错误'
    rmdir "$STACK_DIR/Filebrowser/config"; ln -s "$test_dir" "$STACK_DIR/Filebrowser/config"
    if prepare_filebrowser_storage > "$test_dir/output"; then fail '接受应用目录符号链接'; fi
)
printf '[PASS] FileBrowser 专用目录、UID/GID 与符号链接保护\n'

(
    STACK_DIR="$test_dir/stack"; WATCHTOWER_ACTION=0; MEMOS_IMAGE=neosmemo/memos:0.31.0
    SERVICE_PROFILES=1 select_services >/dev/null
    HOMEPAGE_HOST=nav.example.net
    start_selected_services() { :; }
    docker() {
        if [[ "$1" == --version ]]; then echo 'Docker mock'; return; fi
        if [[ "$*" == 'compose version --short' ]]; then echo mock; return; fi
        if [[ -n "${COMPOSE_TEST_BIN:-}" && "$*" == *'config -q'* ]]; then "$COMPOSE_TEST_BIN" "${@:2}"; fi
    }
    systemctl() { echo active; }
    deploy_services > "$test_dir/output"
    unset HOMEPAGE_HOST
    SERVICE_PROFILES=rss select_services >/dev/null
    collect_homepage
    [[ "$HOMEPAGE_HOST" == nav.example.net ]] || fail '没有读取原域名'
    deploy_services > "$test_dir/output"
    grep -q 'HOMEPAGE_ALLOWED_HOSTS=nav.example.net' "$STACK_DIR/docker-compose.yml" || fail '追加服务覆盖域名'
    grep -q 'image: neosmemo/memos:0.31.0' "$STACK_DIR/docker-compose.yml" || fail 'Memos 未使用固定可用标签'
    grep -q 'WATCHTOWER_SCOPE=vps-init' "$STACK_DIR/docker-compose.yml" || fail '自动更新没有限定范围'
    ! grep -q '/root:/srv' "$STACK_DIR/docker-compose.yml" || fail '仍挂载 root 主目录'
    if [[ -n "${COMPOSE_TEST_BIN:-}" ]]; then
        "$COMPOSE_TEST_BIN" --env-file "$STACK_DIR/.browserless.env" -f "$STACK_DIR/docker-compose.yml" --profile '*' config --format json > "$test_dir/compose.json"
        python3 - "$test_dir/compose.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))['services']
assert len(s)==15
assert s['memos']['labels']['com.centurylinklabs.watchtower.enable']=='false'
assert all(v['labels']['com.centurylinklabs.watchtower.scope']=='vps-init' for k,v in s.items() if k!='memos')
assert s['filebrowser']['user']=='1000:1000'
assert s['watchtower']['environment']['DOCKER_API_VERSION']=='1.44'
PY
    fi
    mkdir -p "$STACK_DIR/memos/data"; touch "$STACK_DIR/memos/data/memos.db"
    sed -i 's|neosmemo/memos:0.31.0|neosmemo/memos:latest|' "$STACK_DIR/docker-compose.yml"
    unset MEMOS_IMAGE
    VPS_SCENE=domestic VPS_MODE=components SERVICE_PROFILES=notes select_services >/dev/null
    VPS_SCENE=domestic VPS_MODE=components
    if (validate_options) > "$test_dir/output" 2>&1; then fail '未拦截旧数据库的不明版本迁移'; fi
    MEMOS_IMAGE=ghcr.io/usememos/memos:0.31.0 validate_options
)
printf '[PASS] Compose 全服务、域名保留、更新范围与 Memos 迁移保护\n'

(
    VPS_SCENE=hk IPERF3_PORT=5201
    ss() { echo 'LISTEN 0 5 *:5201 *:* users:(("iperf3",pid=88,fd=3))'; }
    systemctl() { echo 99; }
    if configure_iperf3 > "$test_dir/output"; then fail '未在写配置前拦截已有端口'; fi
    systemctl() { if [[ "$1" == show ]]; then echo 88; fi; }
    service_is_ready iperf3-server.service || fail '没有识别目标进程监听'
    systemctl() { if [[ "$1" == show ]]; then echo 99; fi; }
    if service_is_ready iperf3-server.service > "$test_dir/output"; then fail '误认其他进程监听为健康'; fi
)
printf '[PASS] iperf3 端口冲突及目标进程监听验收\n'

# 部分索引失败必须通过 Error-Mode=any 转成失败，不能继续升级/安装。
(
    apt-get() {
        case "$1" in
            update) [[ "$*" != *APT::Update::Error-Mode=any* ]];;
            *) touch "$test_dir/unexpected-apt";;
        esac
    }
    VPS_SCENE=domestic VPS_MODE=components
    if (install_base) > "$test_dir/output"; then fail 'APT 部分失败未中止'; fi
    [[ ! -e "$test_dir/unexpected-apt" ]] || fail '索引失败仍继续安装'
)
printf '[PASS] APT 部分索引失败立即中止\n'
