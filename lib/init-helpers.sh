# shellcheck shell=bash

if [ -t 2 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    _CC_C_OK=$(tput setaf 2)
    _CC_C_SKIP=$(tput setaf 3)
    _CC_C_FAIL=$(tput setaf 1)
    _CC_C_INFO=$(tput setaf 4)
    _CC_C_OFF=$(tput sgr0)
else
    _CC_C_OK=""; _CC_C_SKIP=""; _CC_C_FAIL=""; _CC_C_INFO=""; _CC_C_OFF=""
fi

cc_log_ok()   { printf '%s[OK]%s   %s\n'   "$_CC_C_OK"   "$_CC_C_OFF" "$*" >&2; }
cc_log_skip() { printf '%s[SKIP]%s %s\n'   "$_CC_C_SKIP" "$_CC_C_OFF" "$*" >&2; }
cc_log_fail() { printf '%s[FAIL]%s %s\n'   "$_CC_C_FAIL" "$_CC_C_OFF" "$*" >&2; }
cc_log_info() { printf '%s[..]%s   %s\n'   "$_CC_C_INFO" "$_CC_C_OFF" "$*" >&2; }

cc_die() {
    cc_log_fail "$*"
    exit 1
}

cc_ensure_docker_network() {
    local name="$1"
    if docker network inspect "$name" >/dev/null 2>&1; then
        cc_log_skip "docker network $name"
    else
        docker network create "$name" >/dev/null \
            || cc_die "не удалось создать docker network $name"
        cc_log_ok "docker network $name создан"
    fi
}

cc_ensure_docker_volume() {
    local name="$1"
    if docker volume inspect "$name" >/dev/null 2>&1; then
        cc_log_skip "docker volume $name"
    else
        docker volume create "$name" >/dev/null \
            || cc_die "не удалось создать docker volume $name"
        cc_log_ok "docker volume $name создан"
    fi
}

cc_image_exists() {
    docker image inspect "$1" >/dev/null 2>&1
}

cc_container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

cc_container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]
}

cc_check_command() {
    local cmd="$1"
    local hint="${2:-без подсказки}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        cc_die "не найден '$cmd' в PATH. Установка: $hint"
    fi
    cc_log_skip "host: $cmd доступен"
}
