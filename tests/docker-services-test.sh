#!/bin/bash
# Compose 配置使用真实解析器；所有启动和容器内执行均为替身。
set -euo pipefail
export PYTHONUTF8=1
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "$project_dir/tests/.docker-services-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
source "$project_dir/vps-init.sh"
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
if ! python3 -c 'import sys' >/dev/null 2>&1; then python3() { python "$@" | sed 's/\r$//'; }; fi
compose_bin=${COMPOSE_CHECK_BIN:-$project_dir/tests/.tools/docker-compose.exe}
compose_config() {
    if [[ -x "$compose_bin" ]]; then "$compose_bin" "$@"; else command docker compose "$@"; fi
}
compose_config version >/dev/null || fail '需提供 Compose 解析器（COMPOSE_CHECK_BIN 或 Docker Compose 插件）'
read_tty() { printf -v "$1" '%s' "${3-}"; }
sleep() { :; }
systemctl() { printf 'active\n'; }
prepare_filebrowser_storage() { :; }
VPS_MODE=components WATCHTOWER_ACTION=0 SERVICE_WAIT_TIMEOUT=2 HOMEPAGE_HOST=nav.example.com
database_fails=0 installation_required=true
: > "$test_dir/calls"
docker() {
    if [[ "$1" == --version ]]; then echo 'Docker version mock'; return 0; fi
    if [[ "$1" == ps ]]; then return 0; fi
    [[ "$1" == compose ]] || fail "意外调用：$1"
    local -a args=("${@:2}") prefix=()
    local argument
    if [[ "$*" == *'config '* || "$*" == 'compose version --short' ]]; then
        compose_config "${args[@]}"
    elif [[ "$*" == *'ps --all --format json'* ]]; then
        for argument in "${args[@]}"; do
            [[ "$argument" != ps ]] || break
            prefix+=("$argument")
        done
        compose_config "${prefix[@]}" config --services | python3 -c 'import json,sys; print(json.dumps([{"Service":s.strip(),"State":"running","Health":"healthy"} for s in sys.stdin if s.strip()]))'
    elif [[ "$*" == *'exec -T komari curl'* ]]; then
        if [[ "$*" == *'/api/install/status'* ]]; then
            if [[ "$installation_required" == true && ! -f "$test_dir/komari-request.json" ]]; then printf '{"data":{"required":true}}\n200'; else printf '{}\n404'; fi
        else
            cat > "$test_dir/komari-request.json"
            echo komari-install >> "$test_dir/calls"
            installation_required=false
        fi
    elif [[ "$*" == *'exec -T postgresql sh '* ]]; then
        echo provision-databases >> "$test_dir/calls"
        [[ "$database_fails" == 0 ]]
    elif [[ "$*" == *'up -d postgresql'* ]]; then
        echo start-postgresql >> "$test_dir/calls"
    elif [[ "$*" == *'up -d'* ]]; then
        echo start-apps >> "$test_dir/calls"
    fi
}
STACK_DIR="$test_dir/fresh"
SERVICE_PROFILES=8 select_services > "$test_dir/output"
deploy_services > "$test_dir/output" 2>&1 || { cat "$test_dir/output"; fail '新服务生成失败'; }
compose_config "${COMPOSE_ENV_ARGS[@]}" --profile '*' config --format json > "$test_dir/config.json"
python3 - "$test_dir/config.json" "$STACK_DIR" "$test_dir/komari-request.json" <<'PY'
import json, pathlib, sys
config = json.loads(pathlib.Path(sys.argv[1]).read_text())
services = config["services"]
assert set(services) == {"nginx-proxy-manager", "postgresql", "pgadmin4", "watchtower", "homepage",
                         "it-tools", "gitea", "navidrome", "metube", "rsshub", "browserless", "redis",
                         "filebrowser", "openlist", "uptime-kuma", "beszel", "komari", "memos"}
assert all("build" not in service for service in services.values())
root = pathlib.Path(sys.argv[2])
credentials = dict(line.split("=", 1) for line in (root / ".database.env").read_text().splitlines())
assert len(set(credentials[k] for k in credentials if k.endswith("PASSWORD"))) == 8
for service, key in (("nginx-proxy-manager", "DB_POSTGRES_HOST"), ("gitea", "GITEA__database__HOST"), ("openlist", "DB_HOST")):
    assert services[service]["environment"][key].split(":")[0] == "postgresql"
    assert services[service]["depends_on"]["postgresql"]["condition"] == "service_healthy"
assert services["memos"]["environment"]["MEMOS_DRIVER"] == "postgres"
assert "@postgresql:5432/memos?" in services["memos"]["environment"]["MEMOS_DSN"]
assert "ports" not in services["postgresql"]
assert services["postgresql"]["labels"]["com.centurylinklabs.watchtower.enable"] == "false"
assert services["rsshub"]["environment"]["REDIS_URL"] == "redis://redis:6379/"
assert credentials["PGADMIN_DEFAULT_PASSWORD"] == services["pgadmin4"]["environment"]["PGADMIN_DEFAULT_PASSWORD"]
payload = json.loads(pathlib.Path(sys.argv[3]).read_text())
assert payload["password"] == credentials["KOMARI_ADMIN_PASSWORD"]
assert payload["metric_dsn"] == "postgresql://komari:" + credentials["KOMARI_DB_PASSWORD"] + "@postgresql:5432/komari?sslmode=disable"
text = (root / "docker-compose.yml").read_text()
assert not any(credentials[k] in text for k in credentials if k.endswith("PASSWORD"))
PY
[[ $(head -n3 "$test_dir/calls" | paste -sd,) == start-postgresql,provision-databases,start-apps ]] || fail '应用在数据库初始化前启动'
cp "$STACK_DIR/.database.env" "$test_dir/credentials-before"
cp "$STACK_DIR/.database-connections/gitea.env" "$test_dir/gitea-before"
deploy_services > "$test_dir/output" 2>&1 || { cat "$test_dir/output"; fail '重跑失败'; }
cmp -s "$STACK_DIR/.database.env" "$test_dir/credentials-before" || fail '重跑修改了凭据'
cmp -s "$STACK_DIR/.database-connections/gitea.env" "$test_dir/gitea-before" || fail '重跑修改了连接'
[[ $(grep -c '^komari-install$' "$test_dir/calls") == 1 ]] || fail '重跑重置了 Komari'
[[ $(find "$STACK_DIR" -name 'docker-compose.yml.bak.*' | wc -l) == 0 ]] || fail '重复部署生成多余备份'
printf '[PASS] 真实 Compose 解析、新服务连接、独立密码、数据库顺序和重复运行\n'

# 旧数据不切库；旧 Compose 中自定义连接的特殊字符原样保存在受限 env_file。
STACK_DIR="$test_dir/legacy"
mkdir -p "$STACK_DIR/npm/data" "$STACK_DIR/memos/data" "$STACK_DIR/OpenList"
printf 'old\n' > "$STACK_DIR/npm/data/database.sqlite"
printf 'old\n' > "$STACK_DIR/memos/data/memos_prod.db"
printf '{}' > "$STACK_DIR/OpenList/config.json"
STACK_EXISTING_CONFIG_JSON='{"services":{"gitea":{"environment":{"GITEA__database__DB_TYPE":"postgres","GITEA__database__HOST":"legacy-db:5432","GITEA__database__PASSWD":"a$b'"'"'c\\d"}}}}'
prepare_database_storage > "$test_dir/output"
for app in npm memos openlist; do [[ ! -s "$STACK_DIR/.database-connections/$app.env" ]] || fail '旧数据被切到新库'; done
grep -q legacy-db "$STACK_DIR/.database-connections/gitea.env" || fail '丢失原数据库连接'
printf '%s\n' 'services:' '  gitea:' '    image: gitea/gitea:latest' '    env_file: [./.database-connections/gitea.env]' > "$STACK_DIR/check.yml"
compose_config -f "$STACK_DIR/check.yml" config --format json > "$test_dir/legacy-config.json"
python3 - "$test_dir/legacy-config.json" <<'PY'
import json, pathlib, sys
env = json.loads(pathlib.Path(sys.argv[1]).read_text())["services"]["gitea"]["environment"]
# config 输出会再次转义美元符号；容器收到的实际值为还原后的字符串。
assert env["GITEA__database__PASSWD"].replace("$$", "$") == "a$b'c\\d"
PY
(
    mkdir -p "$STACK_DIR/postgresql/data"
    printf '17\n' > "$STACK_DIR/postgresql/data/PG_VERSION"
    mv "$STACK_DIR/.database.env" "$STACK_DIR/.database.env.saved"
    if prepare_database_storage > "$test_dir/output" 2>&1; then fail '缺少原凭据时生成了新密码'; fi
    [[ ! -e "$STACK_DIR/.database.env" ]] || fail '缺少凭据时仍写入新文件'
    mv "$STACK_DIR/.database.env.saved" "$STACK_DIR/.database.env"
    printf 'invalid\n' > "$STACK_DIR/.database.env"
    if prepare_database_storage > "$test_dir/output" 2>&1; then fail '接受损坏凭据文件'; fi
)
printf '[PASS] 已有数据/连接保留、特殊字符还原、凭据丢失和损坏拦截\n'

# 建库失败仍须停止应用启动。
STACK_DIR="$test_dir/fresh"
setup_existing_stack
: > "$test_dir/calls"
if (database_fails=1; start_selected_services 0) > "$test_dir/output" 2>&1; then fail '建库失败仍成功'; fi
! grep -qx start-apps "$test_dir/calls" || fail '建库失败仍启动应用'
bash -n "$STACK_DIR/postgresql/init/10-apps.sh"
printf '[PASS] 全部服务无需本地源码，建库失败时停止应用启动\n'
