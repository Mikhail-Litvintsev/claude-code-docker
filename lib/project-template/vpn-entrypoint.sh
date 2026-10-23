#!/bin/bash
# Gateway: xray and the API broker in the background; the exit of either one stops the container.
# The broker goes upstream through the xray HTTP inbound (port 10809 in inbounds-container.json).
xray run -c /etc/xray/outbound.json -c /etc/xray/routing.json -c /etc/xray/inbounds-container.json &
https_proxy=http://127.0.0.1:10809 http_proxy=http://127.0.0.1:10809 python3 /usr/local/bin/api-broker.py &
wait -n
exit 1
