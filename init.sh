#!/bin/bash
set -euo pipefail

SETUP_DIR=$(dirname "$(realpath "$0")")
PROJECTS_ROOT=$(dirname "$SETUP_DIR")

# shellcheck source=/dev/null
source "$SETUP_DIR/lib/init-helpers.sh"

usage() {
    cat <<EOF
Usage: $0 [--rebuild] [--project <name>] [--skip-projects] [--help]

  --rebuild           пересобрать все образы (общие + проектные, включая сервисные)
  --project <name>    из проектных запустить только указанный (общие шаги идемпотентны)
  --skip-projects     выполнить только общие шаги
  --help              показать эту справку
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
                cc_die "--project требует имя проекта"
            fi
            ONLY_PROJECT="$2"; shift 2 ;;
        --help|-h)        usage; exit 0 ;;
        *) cc_die "неизвестный флаг: $1 (см. --help)" ;;
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
    || cc_die "не работает 'docker compose' (плагин). Установка: apt install docker-compose-plugin"
cc_log_skip "host: docker compose плагин доступен"

# === 2. Сеть cc-net ===================================================
cc_ensure_docker_network cc-net

# === 3. Volume claude-auth ============================================
cc_ensure_docker_volume claude-auth

# === 3.5. Прокси docker.sock для CC-сессий ============================
# tecnativa/docker-socket-proxy — фильтр docker API; CC внутри ccd говорит
# с ним по TCP, к реальному /var/run/docker.sock прямого доступа не имеет.
# Whitelist endpoint'ов — ENV-флаги (минимально-достаточные для CC-сессий)
# + custom haproxy.cfg с explicit deny на /containers/create
# (без него tecnativa с CONTAINERS=1+POST=1 разрешает breakout).
CC_DOCKER_PROXY_IMAGE="tecnativa/docker-socket-proxy:0.3"
CC_DOCKER_PROXY_NAME="cc-docker-proxy"
CC_DOCKER_PROXY_CFG="$SETUP_DIR/cc-docker-proxy/haproxy.cfg"

[ -f "$CC_DOCKER_PROXY_CFG" ] || cc_die "не найден $CC_DOCKER_PROXY_CFG"

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
    cc_log_info "запуск $CC_DOCKER_PROXY_NAME"
    docker rm -f "$CC_DOCKER_PROXY_NAME" >/dev/null 2>&1 || true
    cc_image_exists "$CC_DOCKER_PROXY_IMAGE" \
        || docker pull "$CC_DOCKER_PROXY_IMAGE" >/dev/null \
        || cc_die "не удалось скачать $CC_DOCKER_PROXY_IMAGE"
    # --read-only намеренно НЕ ставим: tecnativa entrypoint sed'ит
    # haproxy.cfg.template → haproxy.cfg при каждом старте, что требует
    # writable /usr/local/etc/haproxy/. Альтернатива (--tmpfs над этим
    # каталогом) ломает встроенные errorfile'ы образа. Defense-in-depth
    # обеспечивают cap-drop, no-new-privileges, ro-сокет и закрытая cc-net.
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
        || cc_die "не удалось запустить $CC_DOCKER_PROXY_NAME"
    cc_log_ok "$CC_DOCKER_PROXY_NAME запущен"
fi

# === 4. Базовый образ cc-image (с runtime-проверкой UID/GID) ==========
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
        cc_log_info "cc-image UID/GID ($image_uid/$image_gid) не совпадает с host ($HOST_UID/$HOST_GID) — пересобираем"
        need_rebuild_base=1
        cascade_rebuild=1
    fi
fi

if [ "$need_rebuild_base" -eq 1 ]; then
    cc_log_info "сборка cc-image (UID=$HOST_UID, GID=$HOST_GID)"
    docker build \
        --build-arg "UID=$HOST_UID" --build-arg "GID=$HOST_GID" \
        -t cc-image "$SETUP_DIR" \
        || cc_die "не удалось собрать cc-image"
    cc_log_ok "cc-image собран"
else
    cc_log_skip "cc-image (UID/GID совпадают)"
fi

# === 5. PATH в ~/.bashrc ==============================================
BASHRC="$HOME/.bashrc"
[ -f "$BASHRC" ] || touch "$BASHRC"
PATH_LINE="export PATH=\"\$PATH:$SETUP_DIR/bin\"  # claude-code-docker:$SETUP_DIR"
PATH_MARKER="# claude-code-docker:$SETUP_DIR"

if grep -Fq "$PATH_MARKER" "$BASHRC"; then
    cc_log_skip "PATH: маркер уже в $BASHRC"
elif grep -Fq "$SETUP_DIR/bin" "$BASHRC"; then
    cc_log_skip "PATH: ручная запись на $SETUP_DIR/bin найдена в $BASHRC; маркер не дописываем во избежание задвоения"
else
    printf '\n%s\n' "$PATH_LINE" >> "$BASHRC"
    cc_log_ok "PATH: добавлено в $BASHRC (применить: source $BASHRC или новый терминал)"
fi

# === 6. IDE плагин — только инструкция (не автоматизируется) ========
cc_log_info "IDE плагин: настроить вручную в Settings → Tools → Claude Code [Beta]"
printf '         Claude command: %s/bin/ccd\n' "$SETUP_DIR" >&2
printf '         Accept connections from all network interfaces: yes (обязательно для env-injection)\n' >&2

# === 7. Запуск проектных init.sh ======================================
project_results=()

if [ "$SKIP_PROJECTS" -eq 1 ]; then
    cc_log_info "пропуск проектных init.sh (--skip-projects)"
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
            cc_log_fail "<<< $proj_name/init.sh упал, продолжаем дальше"
        fi
    done
    shopt -u nullglob
fi

# === 8. Финальная сводка ==============================================
echo >&2
cc_log_info "===== СВОДКА ====="
cc_log_ok "общие шаги: cc-net, claude-auth, cc-docker-proxy, cc-image, PATH, IDE-инструкция"

any_fail=0
if [ "${#project_results[@]}" -gt 0 ]; then
    for entry in "${project_results[@]}"; do
        name="${entry%%:*}"
        status="${entry#*:}"
        case "$status" in
            ok)        cc_log_ok   "проект $name" ;;
            filtered)  cc_log_info "проект $name пропущен флагом --project" ;;
            fail)      cc_log_fail "проект $name"; any_fail=1 ;;
        esac
    done
fi

cat >&2 <<EOF

Финальный шаг — авторизация OAuth (вручную, автоматизировать нельзя):

  cd $PROJECTS_ROOT/<project> && ccd

При первом запуске CC внутри контейнера инициирует OAuth-flow автоматически.
Если auto-prompt не появился — внутри сессии: /login.
(Бинарь claude в cc-image не установлен — он живёт в volume claude-cc-bin,
 который ccd прогревает автоматически. Прямой docker run cc-image claude
 без монтажа этого volume и переопределения PATH не работает.)

EOF

if [ "$any_fail" -eq 1 ]; then
    exit 1
fi
exit 0
