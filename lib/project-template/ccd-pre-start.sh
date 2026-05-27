#!/bin/bash
# Sourced by ccd before container launch.
# Ensures the VPN service container has correct config (ports, env, volume).

if [ -z "${VPN_CONTAINER:-}" ] || [ -z "${VPN_IMAGE:-}" ]; then
    return 0
fi

vpn_config_hash=$(printf '%s\0' "${VPN_CREATE_ARGS[@]:+${VPN_CREATE_ARGS[@]}}" | sha256sum | cut -d' ' -f1)
vpn_actual_hash=$(docker inspect -f '{{index .Config.Labels "ccd.config-hash"}}' "$VPN_CONTAINER" 2>/dev/null || true)

if [ "$vpn_config_hash" != "$vpn_actual_hash" ]; then
    echo "ccd: recreating $VPN_CONTAINER (config changed or container missing)" >&2
    docker stop "$VPN_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$VPN_CONTAINER" >/dev/null 2>&1 || true
    docker create --name "$VPN_CONTAINER" --network cc-net \
        --label "ccd.config-hash=$vpn_config_hash" \
        ${VPN_CREATE_ARGS[@]:+"${VPN_CREATE_ARGS[@]}"} \
        "$VPN_IMAGE" >/dev/null \
        || { echo "ccd: failed to create $VPN_CONTAINER" >&2; exit 1; }
    echo "ccd: $VPN_CONTAINER created" >&2
fi

if [ "$(docker inspect -f '{{.State.Status}}' "$VPN_CONTAINER" 2>/dev/null)" != "running" ]; then
    docker start "$VPN_CONTAINER" >/dev/null 2>&1
fi
