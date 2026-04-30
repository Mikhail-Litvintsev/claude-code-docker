#!/bin/bash
# Entrypoint сервисного VPN-контейнера: xray-клиент + socat-релей.
# DB_REMOTE_HOST/DB_REMOTE_PORT — целевой адрес за прокси, передаётся через -e
# в `docker create` из проектного init.sh. xray-config монтируется read-only
# из <setup>/<project-name>/vpn-config/config.json.

set -euo pipefail

: "${DB_REMOTE_HOST:?DB_REMOTE_HOST is required}"
: "${DB_REMOTE_PORT:?DB_REMOTE_PORT is required}"

xray run -c /etc/xray/config.json &
XRAY_PID=$!
sleep 2
if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    echo "xray failed to start" >&2
    exit 1
fi

socat TCP-LISTEN:15433,fork,reuseaddr,bind=0.0.0.0 \
    SOCKS4A:127.0.0.1:${DB_REMOTE_HOST}:${DB_REMOTE_PORT},socksport=10808 &

trap 'kill -TERM "$XRAY_PID" 2>/dev/null' TERM INT
wait "$XRAY_PID"
