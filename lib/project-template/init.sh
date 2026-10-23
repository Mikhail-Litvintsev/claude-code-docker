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
        *) cc_die "$PROJECT_NAME/init.sh: unknown flag $1" ;;
    esac
done

# === 1. Convention validation ========================================
[ -d "$PROJECT_DIR" ] || cc_die "project $PROJECT_DIR not found (the setup folder name '$PROJECT_NAME' must match the project folder name)"
cc_log_skip "project found: $PROJECT_DIR"

# === 2. vpn-config (outbound.json is a secret issued by the VPN provider) ==
VPN_OUTBOUND="$SCRIPT_DIR/vpn-config/outbound.json"
if [ -f "$VPN_OUTBOUND" ]; then
    cc_log_skip "vpn-config/outbound.json already in place"
else
    cc_die "not found: $VPN_OUTBOUND — generate it from the vless link: python3 $SETUP_DIR/lib/xray-outbound-from-link.py '<vless://...>' $VPN_OUTBOUND"
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
        || cc_die "building cc-image-expro requires the base cc-image — run $SETUP_DIR/init.sh"
    cc_log_info "building cc-image-expro"
    docker build -t cc-image-expro "$SCRIPT_DIR" \
        || cc_die "failed to build cc-image-expro"
    cc_log_ok "cc-image-expro built"
else
    cc_log_skip "cc-image-expro"
fi

# === 4. cc-expro-vpn-image (FROM debian:bookworm-slim, not base-derived) =
# Built from the setup root: Dockerfile.vpn copies lib/api-broker.py and expro/vpn-entrypoint.sh.
need_rebuild_vpn_image=0
if [ "$REBUILD" -eq 1 ]; then
    need_rebuild_vpn_image=1
elif ! cc_image_exists cc-expro-vpn-image; then
    need_rebuild_vpn_image=1
fi

if [ "$need_rebuild_vpn_image" -eq 1 ]; then
    cc_log_info "building cc-expro-vpn-image"
    docker build -t cc-expro-vpn-image -f "$SCRIPT_DIR/Dockerfile.vpn" "$SCRIPT_DIR/.." \
        || cc_die "failed to build cc-expro-vpn-image"
    cc_log_ok "cc-expro-vpn-image built"
else
    cc_log_skip "cc-expro-vpn-image (does not depend on host UID)"
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
        cc_log_info "credentials: ENV variables"
    else
        local src found=""
        for src in "$PROJECT_DIR/db-query.sh" "$PROJECT_DIR/temp-backup/db-query.sh"; do
            if [ -f "$src" ]; then
                user=$(extract_kv DB_USER    "$src")
                name=$(extract_kv DB_NAME    "$src")
                pass=$(extract_kv PGPASSWORD "$src")
                if [ -n "$user" ] && [ -n "$name" ] && [ -n "$pass" ]; then
                    cc_log_info "credentials: $src"
                    found=1
                    break
                fi
            fi
        done
        [ -n "$found" ] || cc_die "expro credentials not found: set EXPRO_DB_USER, EXPRO_DB_NAME, EXPRO_PGPASSWORD or restore $PROJECT_DIR/temp-backup/db-query.sh"
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
        cc_log_info "$CRED_FILE: missing fields: ${missing[*]} — update manually (template requires all: ${CRED_KEYS[*]})"
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
    cc_log_ok "db-credentials.env created (chmod 600)"
    cc_log_info "WARNING: $CRED_FILE is a secret. Internal project (the project folder is the repository): $PROJECT_DIR/.gitignore must ignore it. External project (a workspace over repositories): keep it in the workspace, outside every repository"
fi

# === 5a. ~/.config/ticket-services/expro.env (API keys read by the gateway broker) ==
# Checked only, never written: the directory is mounted read-only into cc-expro-vpn
# (VPN_CREATE_ARGS); the session container reaches the keys through TICKET_SERVICES_BROKER.
TICKET_CRED_FILE="$HOME/.config/ticket-services/$PROJECT_NAME.env"
if [ -f "$TICKET_CRED_FILE" ] && grep -qE '^TICKETHOST_API_KEY=.+' "$TICKET_CRED_FILE" && grep -qE '^CODEHOST_TOKEN=.+' "$TICKET_CRED_FILE"; then
    cc_log_skip "$TICKET_CRED_FILE"
else
    cc_log_info "$TICKET_CRED_FILE: fill in TICKETHOST_API_KEY, CODEHOST_TOKEN, HTTPS_PROXY, TICKETHOST_URL, CODEHOST_URL and CODEHOST_PROJECT by hand (directory 700, file 600)"
fi

# === 6. ccd-config.sh ================================================
CCD_CFG="$SCRIPT_DIR/ccd-config.sh"
CCD_TEMPLATE='IMAGE=cc-image-expro
CONTAINER_NAME_PREFIX=cc-expro
COMPOSE_NETWORKS=("proxy" "expro-db")
VPN_CONTAINER=cc-expro-vpn
VPN_REFCOUNT_FILE="$PROJECT_DIR/.claude/cc-expro-vpn.users"
VPN_IMAGE=cc-expro-vpn-image
VPN_CREATE_ARGS=(
    --network-alias git.example.com
    -v "$SETUP_DIR/$PROJECT_NAME/vpn-config:/etc/xray:ro"
    -v "$HOME/.config/ticket-services:/etc/ticket-services:ro"
)
CONTAINER_ENV=("TICKET_SERVICES_BROKER=http://cc-expro-vpn:8080")
EXPOSE_GIT_IDENTITY=1
EXPOSE_GIT_PUSH=0
SSH_AGENT_KEY=""
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
        cc_log_info "$CCD_CFG: template requires fields: ${missing[*]} — update manually"
    else
        cc_log_skip "ccd-config.sh"
    fi
else
    printf '%s\n' "$CCD_TEMPLATE" > "$CCD_CFG"
    chmod 644 "$CCD_CFG"
    cc_log_ok "ccd-config.sh created"
fi

# === 6.5. mcp.json (project-level MCP servers) =======================
MCP_CFG="$SCRIPT_DIR/mcp.json"
if [ -f "$MCP_CFG" ]; then
    cc_log_skip "mcp.json"
else
    printf '{\n  "mcpServers": {}\n}\n' > "$MCP_CFG"
    chmod 644 "$MCP_CFG"
    cc_log_ok "mcp.json created (empty template; add servers manually)"
fi

# === 6.6. .chrome-devtools-mcp (filesystem root of chrome-devtools-mcp) ===
# The --filesystem-root of the server must exist before it starts.
# Drop this step if the project has no Chrome DevTools MCP in mcp.json.
CDT_OUT_DIR="$PROJECT_DIR/.chrome-devtools-mcp"
if [ -d "$CDT_OUT_DIR" ]; then
    cc_log_skip ".chrome-devtools-mcp"
else
    mkdir -p "$CDT_OUT_DIR"
    cc_log_ok ".chrome-devtools-mcp created"
fi

# === 7. cc-expro-vpn (container; create without run) =================
# shellcheck source=/dev/null
source "$SCRIPT_DIR/ccd-config.sh"

vpn_config_hash=$(printf '%s\0' "${VPN_CREATE_ARGS[@]:+${VPN_CREATE_ARGS[@]}}" | sha256sum | cut -d' ' -f1)
vpn_actual_hash=$(docker inspect -f '{{index .Config.Labels "ccd.config-hash"}}' "$VPN_CONTAINER" 2>/dev/null || true)

need_recreate_vpn=0
if [ "$need_rebuild_vpn_image" -eq 1 ]; then
    need_recreate_vpn=1
elif [ "$vpn_config_hash" != "$vpn_actual_hash" ]; then
    need_recreate_vpn=1
fi

if [ "$need_recreate_vpn" -eq 1 ]; then
    if cc_container_running "$VPN_CONTAINER"; then
        docker stop "$VPN_CONTAINER" >/dev/null
    fi
    docker rm -f "$VPN_CONTAINER" >/dev/null 2>&1 || true
    docker create --name "$VPN_CONTAINER" --network cc-net \
        --label "ccd.config-hash=$vpn_config_hash" \
        ${VPN_CREATE_ARGS[@]:+"${VPN_CREATE_ARGS[@]}"} \
        "$VPN_IMAGE" >/dev/null \
        || cc_die "failed to create $VPN_CONTAINER"
    cc_log_ok "$VPN_CONTAINER created"
else
    cc_log_skip "$VPN_CONTAINER"
fi

cc_log_ok "$PROJECT_NAME/init.sh: ok"
exit 0
