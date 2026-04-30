#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
SETUP_DIR=$(dirname "$SCRIPT_DIR")
PROJECTS_ROOT=$(dirname "$SETUP_DIR")
PROJECT_NAME=$(basename "$SCRIPT_DIR")
PROJECT_DIR="$PROJECTS_ROOT/$PROJECT_NAME"

# shellcheck source=/dev/null
source "$SETUP_DIR/lib/init-helpers.sh"

REBUILD=0
REBUILD_BASE_DERIVED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rebuild)              REBUILD=1; shift ;;
        --rebuild-base-derived) REBUILD_BASE_DERIVED=1; shift ;;
        *) cc_die "$PROJECT_NAME/init.sh: неизвестный флаг $1" ;;
    esac
done

# === 1. Валидация соглашения =========================================
[ -d "$PROJECT_DIR" ] || cc_die "проект $PROJECT_DIR не найден (имя setup-папки '$PROJECT_NAME' должно совпадать с папкой проекта)"
cc_log_skip "проект найден: $PROJECT_DIR"

# === 2. xray-config (секрет, копируется только если отсутствует) =====
HOST_XRAY_SRC="$PROJECT_DIR/xray-config.json"
TARGET_XRAY="$SCRIPT_DIR/vpn-config/config.json"
if [ -f "$TARGET_XRAY" ]; then
    cc_log_skip "vpn-config/config.json уже на месте"
else
    [ -f "$HOST_XRAY_SRC" ] || cc_die "не найден $HOST_XRAY_SRC — без xray-конфига VPN-контейнер не запустится"
    mkdir -p "$(dirname "$TARGET_XRAY")"
    cp "$HOST_XRAY_SRC" "$TARGET_XRAY"
    chmod 600 "$TARGET_XRAY"
    cc_log_ok "vpn-config/config.json скопирован из $HOST_XRAY_SRC"
fi

# === 3. cc-image-expro (FROM cc-image — base-derived) ================
need_rebuild_app=0
if [ "$REBUILD" -eq 1 ] || [ "$REBUILD_BASE_DERIVED" -eq 1 ]; then
    need_rebuild_app=1
elif ! cc_image_exists cc-image-expro; then
    need_rebuild_app=1
fi

if [ "$need_rebuild_app" -eq 1 ]; then
    cc_image_exists cc-image \
        || cc_die "для сборки cc-image-expro нужен базовый cc-image — запустите $SETUP_DIR/init.sh"
    cc_log_info "сборка cc-image-expro"
    docker build -t cc-image-expro "$SCRIPT_DIR" \
        || cc_die "не удалось собрать cc-image-expro"
    cc_log_ok "cc-image-expro собран"
else
    cc_log_skip "cc-image-expro"
fi

# === 4. cc-expro-vpn-image (FROM debian:bookworm-slim, не base-derived) =
need_rebuild_vpn_image=0
if [ "$REBUILD" -eq 1 ]; then
    need_rebuild_vpn_image=1
elif ! cc_image_exists cc-expro-vpn-image; then
    need_rebuild_vpn_image=1
fi

if [ "$need_rebuild_vpn_image" -eq 1 ]; then
    cc_log_info "сборка cc-expro-vpn-image"
    docker build -t cc-expro-vpn-image -f "$SCRIPT_DIR/Dockerfile.vpn" "$SCRIPT_DIR" \
        || cc_die "не удалось собрать cc-expro-vpn-image"
    cc_log_ok "cc-expro-vpn-image собран"
else
    cc_log_skip "cc-expro-vpn-image (не зависит от UID хоста)"
fi

# === 5. db-credentials.env ===========================================
CRED_FILE="$PROJECT_DIR/.claude/db-credentials.env"
mkdir -p "$(dirname "$CRED_FILE")"

CRED_KEYS=(DB_USER DB_NAME PGPASSWORD)

extract_kv() {
    local key="$1" file="$2"
    grep -E "^${key}=" "$file" | head -1 | sed -E "s/^${key}=\"?([^\"]*)\"?\$/\1/"
}

resolve_credentials() {
    local user="" name="" pass=""
    if [ -n "${EXPRO_DB_USER:-}" ] && [ -n "${EXPRO_DB_NAME:-}" ] && [ -n "${EXPRO_PGPASSWORD:-}" ]; then
        user="$EXPRO_DB_USER"; name="$EXPRO_DB_NAME"; pass="$EXPRO_PGPASSWORD"
        cc_log_info "креденшалы: ENV-переменные"
    else
        local src found=""
        for src in "$PROJECT_DIR/db-query.sh" "$PROJECT_DIR/temp-backup/db-query.sh"; do
            if [ -f "$src" ]; then
                user=$(extract_kv DB_USER    "$src")
                name=$(extract_kv DB_NAME    "$src")
                pass=$(extract_kv PGPASSWORD "$src")
                if [ -n "$user" ] && [ -n "$name" ] && [ -n "$pass" ]; then
                    cc_log_info "креденшалы: $src"
                    found=1
                    break
                fi
            fi
        done
        [ -n "$found" ] || cc_die "не найдены креденшалы expro: задайте EXPRO_DB_USER, EXPRO_DB_NAME, EXPRO_PGPASSWORD или восстановите $PROJECT_DIR/temp-backup/db-query.sh"
    fi
    DB_USER_LINE="DB_USER=$user"
    DB_NAME_LINE="DB_NAME=$name"
    DB_PASS_LINE="PGPASSWORD=$pass"
}

if [ -f "$CRED_FILE" ]; then
    missing=()
    for key in "${CRED_KEYS[@]}"; do
        grep -q "^${key}=" "$CRED_FILE" || missing+=("$key")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        cc_log_info "$CRED_FILE: отсутствуют поля: ${missing[*]} — обновите вручную (шаблон требует все: ${CRED_KEYS[*]})"
    else
        cc_log_skip "db-credentials.env"
    fi
else
    resolve_credentials
    (
        umask 077
        {
            echo "$DB_USER_LINE"
            echo "$DB_NAME_LINE"
            echo "$DB_PASS_LINE"
        } > "$CRED_FILE"
    )
    chmod 600 "$CRED_FILE"
    cc_log_ok "db-credentials.env создан (chmod 600)"
    cc_log_info "ВНИМАНИЕ: $CRED_FILE — секрет; за его игнор отвечает $PROJECT_DIR/.gitignore (репозиторий проекта)"
fi

# === 6. ccd-config.sh ================================================
CCD_CFG="$SCRIPT_DIR/ccd-config.sh"
CCD_TEMPLATE='IMAGE=cc-image-expro
CONTAINER_NAME_PREFIX=cc-expro
COMPOSE_NETWORKS=("proxy" "expro-db")
VPN_CONTAINER=cc-expro-vpn
VPN_REFCOUNT_FILE="$PROJECT_DIR/.claude/cc-expro-vpn.users"
EXPOSE_GIT_IDENTITY=1
EXPOSE_GIT_PUSH=0
EXPOSE_GITCONFIG=0
LOCK_GIT_INTERNALS=1
LOCK_GITMODULES=0'

CCD_KEYS=()
while IFS= read -r line; do
    [[ "$line" =~ ^[A-Z_]+= ]] && CCD_KEYS+=("${line%%=*}")
done <<< "$CCD_TEMPLATE"

if [ -f "$CCD_CFG" ]; then
    missing=()
    for key in "${CCD_KEYS[@]}"; do
        grep -Eq "^${key}=" "$CCD_CFG" || missing+=("$key")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        cc_log_info "$CCD_CFG: шаблон требует поля: ${missing[*]} — обновите вручную"
    else
        cc_log_skip "ccd-config.sh"
    fi
else
    printf '%s\n' "$CCD_TEMPLATE" > "$CCD_CFG"
    chmod 644 "$CCD_CFG"
    cc_log_ok "ccd-config.sh создан"
fi

# === 6.5. mcp.json (project-level MCP servers) =======================
MCP_CFG="$SCRIPT_DIR/mcp.json"
if [ -f "$MCP_CFG" ]; then
    cc_log_skip "mcp.json"
else
    printf '{\n  "mcpServers": {}\n}\n' > "$MCP_CFG"
    chmod 644 "$MCP_CFG"
    cc_log_ok "mcp.json создан (пустой шаблон; добавьте серверы вручную)"
fi

# === 7. cc-expro-vpn (контейнер; create без run) =====================
need_recreate_vpn=0
if [ "$need_rebuild_vpn_image" -eq 1 ]; then
    need_recreate_vpn=1
elif ! cc_container_exists cc-expro-vpn; then
    need_recreate_vpn=1
fi

if [ "$need_recreate_vpn" -eq 1 ]; then
    if cc_container_running cc-expro-vpn; then
        docker stop cc-expro-vpn >/dev/null
    fi
    docker rm -f cc-expro-vpn >/dev/null 2>&1 || true
    docker create --name cc-expro-vpn --network cc-net \
        -e DB_REMOTE_HOST=198.51.100.10 \
        -e DB_REMOTE_PORT=5433 \
        -v "$SCRIPT_DIR/vpn-config:/etc/xray:ro" \
        cc-expro-vpn-image >/dev/null \
        || cc_die "не удалось создать cc-expro-vpn"
    cc_log_ok "cc-expro-vpn создан"
else
    cc_log_skip "cc-expro-vpn"
fi

cc_log_ok "$PROJECT_NAME/init.sh: ok"
exit 0
