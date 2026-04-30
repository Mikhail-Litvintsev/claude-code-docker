#!/bin/bash
set -euo pipefail

SETUP_DIR=$(dirname "$(realpath "$0")")
PROJECTS_ROOT=$(dirname "$SETUP_DIR")

# shellcheck source=/dev/null
source "$SETUP_DIR/lib/init-helpers.sh"

usage() {
    cat <<EOF
Usage: $0 [--rebuild] [--project <name>] [--skip-projects] [--help]

  --rebuild           rebuild all images (shared + per-project, including service)
  --project <name>    of the projects, only run the named one (shared steps are idempotent)
  --skip-projects     run only the shared steps
  --help              show this help
EOF
}

REBUILD=0
SKIP_PROJECTS=0
ONLY_PROJECT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rebuild)        REBUILD=1; shift ;;
        --skip-projects)  SKIP_PROJECTS=1; shift ;;
        --project)
            if [ $# -lt 2 ] || [[ "$2" == --* ]]; then
                cc_die "--project requires a project name"
            fi
            ONLY_PROJECT="$2"; shift 2 ;;
        --help|-h)        usage; exit 0 ;;
        *) cc_die "unknown flag: $1 (see --help)" ;;
    esac
done

cc_log_info "setup: $SETUP_DIR"
cc_log_info "projects-root: $PROJECTS_ROOT"

# === 1. Prerequisites =================================================
cc_check_command docker          "https://docs.docker.com/engine/install/"
cc_check_command jq              "apt install jq"
cc_check_command flock           "apt install util-linux"
cc_check_command realpath        "apt install coreutils"
docker compose version >/dev/null 2>&1 \
    || cc_die "'docker compose' (plugin) not working. Install: apt install docker-compose-plugin"
cc_log_skip "host: docker compose plugin available"

# === 2. cc-net network ================================================
cc_ensure_docker_network cc-net

# === 3. claude-auth volume ============================================
cc_ensure_docker_volume claude-auth

# === 3.5. docker.sock proxy for CC sessions ===========================
# tecnativa/docker-socket-proxy — docker API filter; CC inside ccd talks
# to it over TCP and has no direct access to the real /var/run/docker.sock.
# Endpoint whitelist — ENV flags (minimum needed for CC sessions)
# + custom haproxy.cfg with an explicit deny on /containers/create
# (without it, tecnativa with CONTAINERS=1+POST=1 allows breakout).
CC_DOCKER_PROXY_IMAGE="tecnativa/docker-socket-proxy:0.3"
CC_DOCKER_PROXY_NAME="cc-docker-proxy"
CC_DOCKER_PROXY_CFG="$SETUP_DIR/cc-docker-proxy/haproxy.cfg"

[ -f "$CC_DOCKER_PROXY_CFG" ] || cc_die "not found: $CC_DOCKER_PROXY_CFG"

proxy_cfg_hash=$(md5sum "$CC_DOCKER_PROXY_CFG" | awk '{print $1}')

cc_proxy_running=0
proxy_cfg_match=0
if cc_container_exists "$CC_DOCKER_PROXY_NAME"; then
    proxy_state=$(docker inspect -f '{{.State.Status}}' "$CC_DOCKER_PROXY_NAME" 2>/dev/null || echo "")
    [ "$proxy_state" = "running" ] && cc_proxy_running=1
    existing_hash=$(docker inspect -f '{{ index .Config.Labels "cc.haproxy-cfg-md5" }}' \
        "$CC_DOCKER_PROXY_NAME" 2>/dev/null || echo "")
    [ "$existing_hash" = "$proxy_cfg_hash" ] && proxy_cfg_match=1
fi

if [ "$cc_proxy_running" -eq 1 ] && [ "$proxy_cfg_match" -eq 1 ] && [ "$REBUILD" -eq 0 ]; then
    cc_log_skip "docker proxy ($CC_DOCKER_PROXY_NAME)"
else
    cc_log_info "starting $CC_DOCKER_PROXY_NAME"
    docker rm -f "$CC_DOCKER_PROXY_NAME" >/dev/null 2>&1 || true
    cc_image_exists "$CC_DOCKER_PROXY_IMAGE" \
        || docker pull "$CC_DOCKER_PROXY_IMAGE" >/dev/null \
        || cc_die "failed to pull $CC_DOCKER_PROXY_IMAGE"
    # --read-only is deliberately NOT set: the tecnativa entrypoint seds
    # haproxy.cfg.template → haproxy.cfg on every start, which requires a
    # writable /usr/local/etc/haproxy/. The alternative (--tmpfs over that
    # directory) breaks the image's built-in errorfiles. Defense-in-depth
    # comes from cap-drop, no-new-privileges, the ro socket, and the
    # closed cc-net network.
    docker run -d --name "$CC_DOCKER_PROXY_NAME" \
        --network cc-net \
        --restart=unless-stopped \
        --cap-drop=ALL --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID \
        --security-opt=no-new-privileges \
        --label "cc.haproxy-cfg-md5=$proxy_cfg_hash" \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v "$CC_DOCKER_PROXY_CFG:/usr/local/etc/haproxy/haproxy.cfg.template:ro" \
        -e CONTAINERS=1 \
        -e EXEC=1 \
        -e POST=1 \
        -e NETWORKS=1 \
        -e INFO=1 \
        -e VERSION=1 \
        -e PING=1 \
        "$CC_DOCKER_PROXY_IMAGE" >/dev/null \
        || cc_die "failed to start $CC_DOCKER_PROXY_NAME"
    cc_log_ok "$CC_DOCKER_PROXY_NAME started"
fi

# === 4. Base cc-image (with runtime UID/GID check) ====================
HOST_UID=$(id -u)
HOST_GID=$(id -g)
cascade_rebuild=0
need_rebuild_base=0

if [ "$REBUILD" -eq 1 ]; then
    need_rebuild_base=1
elif ! cc_image_exists cc-image; then
    need_rebuild_base=1
else
    image_uid=$(docker run --rm cc-image id -u 2>/dev/null || echo "")
    image_gid=$(docker run --rm cc-image id -g 2>/dev/null || echo "")
    if [ "$image_uid" != "$HOST_UID" ] || [ "$image_gid" != "$HOST_GID" ]; then
        cc_log_info "cc-image UID/GID ($image_uid/$image_gid) does not match host ($HOST_UID/$HOST_GID) — rebuilding"
        need_rebuild_base=1
        cascade_rebuild=1
    fi
fi

if [ "$need_rebuild_base" -eq 1 ]; then
    cc_log_info "building cc-image (UID=$HOST_UID, GID=$HOST_GID)"
    docker build \
        --build-arg "UID=$HOST_UID" --build-arg "GID=$HOST_GID" \
        -t cc-image "$SETUP_DIR" \
        || cc_die "failed to build cc-image"
    cc_log_ok "cc-image built"
else
    cc_log_skip "cc-image (UID/GID match)"
fi

# === 5. PATH in ~/.bashrc =============================================
BASHRC="$HOME/.bashrc"
[ -f "$BASHRC" ] || touch "$BASHRC"
PATH_LINE="export PATH=\"\$PATH:$SETUP_DIR/bin\"  # claude-code-docker:$SETUP_DIR"
PATH_MARKER="# claude-code-docker:$SETUP_DIR"

if grep -Fq "$PATH_MARKER" "$BASHRC"; then
    cc_log_skip "PATH: marker already in $BASHRC"
elif grep -Fq "$SETUP_DIR/bin" "$BASHRC"; then
    cc_log_skip "PATH: manual entry for $SETUP_DIR/bin found in $BASHRC; not appending the marker to avoid duplication"
else
    printf '\n%s\n' "$PATH_LINE" >> "$BASHRC"
    cc_log_ok "PATH: appended to $BASHRC (apply: source $BASHRC or open a new terminal)"
fi

# === 6. IDE plugin — instructions only (not automated) ================
cc_log_info "IDE plugin: configure manually in Settings → Tools → Claude Code [Beta]"
printf '         Claude command: %s/bin/ccd\n' "$SETUP_DIR" >&2
printf '         Accept connections from all network interfaces: yes (required for env-injection)\n' >&2

# === 7. Run project init.sh scripts ===================================
project_results=()

if [ "$SKIP_PROJECTS" -eq 1 ]; then
    cc_log_info "skipping project init.sh scripts (--skip-projects)"
else
    project_args=()
    if [ "$REBUILD" -eq 1 ]; then
        project_args+=(--rebuild)
    elif [ "$cascade_rebuild" -eq 1 ]; then
        project_args+=(--rebuild-base-derived)
    fi

    shopt -s nullglob
    for proj_init in "$SETUP_DIR"/*/init.sh; do
        proj_dir=$(dirname "$proj_init")
        proj_name=$(basename "$proj_dir")

        if [ -n "$ONLY_PROJECT" ] && [ "$ONLY_PROJECT" != "$proj_name" ]; then
            project_results+=("$proj_name:filtered")
            continue
        fi

        cc_log_info ">>> $proj_name/init.sh"
        if [ "${#project_args[@]}" -gt 0 ]; then
            run_status=0
            bash "$proj_init" "${project_args[@]}" || run_status=$?
        else
            run_status=0
            bash "$proj_init" || run_status=$?
        fi
        if [ "$run_status" -eq 0 ]; then
            project_results+=("$proj_name:ok")
            cc_log_ok "<<< $proj_name/init.sh"
        else
            project_results+=("$proj_name:fail")
            cc_log_fail "<<< $proj_name/init.sh failed, continuing"
        fi
    done
    shopt -u nullglob
fi

# === 8. Final summary =================================================
echo >&2
cc_log_info "===== SUMMARY ====="
cc_log_ok "shared steps: cc-net, claude-auth, cc-docker-proxy, cc-image, PATH, IDE instructions"

any_fail=0
if [ "${#project_results[@]}" -gt 0 ]; then
    for entry in "${project_results[@]}"; do
        name="${entry%%:*}"
        status="${entry#*:}"
        case "$status" in
            ok)        cc_log_ok   "project $name" ;;
            filtered)  cc_log_info "project $name skipped by --project flag" ;;
            fail)      cc_log_fail "project $name"; any_fail=1 ;;
        esac
    done
fi

cat >&2 <<EOF

Final step — OAuth authorization (manual, cannot be automated):

  cd $PROJECTS_ROOT/<project> && ccd

On the first run, CC inside the container initiates the OAuth flow automatically.
If the auto-prompt does not show up — inside the session run: /login.
(The claude binary is not installed in cc-image — it lives in the claude-cc-bin volume,
 which ccd warms up automatically. A direct docker run cc-image claude without mounting
 this volume and overriding PATH will not work.)

EOF

if [ "$any_fail" -eq 1 ]; then
    exit 1
fi
exit 0
