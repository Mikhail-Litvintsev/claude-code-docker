#!/usr/bin/env python3
import json
import os
import sys
from urllib.parse import parse_qs, unquote, urlparse


def stream_settings(params: dict) -> dict:
    network = params.get("type", "tcp")
    security = params.get("security", "none")
    settings = {"network": network, "security": security}
    if security == "reality":
        settings["realitySettings"] = {
            "serverName": params.get("sni", ""),
            "fingerprint": params.get("fp", "chrome"),
            "publicKey": params.get("pbk", ""),
            "shortId": params.get("sid", ""),
            "spiderX": unquote(params.get("spx", "/")),
        }
    elif security == "tls":
        settings["tlsSettings"] = {
            "serverName": params.get("sni", ""),
            "fingerprint": params.get("fp", "chrome"),
        }
    if network == "grpc":
        settings["grpcSettings"] = {"serviceName": params.get("serviceName", "")}
    elif network == "ws":
        settings["wsSettings"] = {
            "path": unquote(params.get("path", "/")),
            "headers": {"Host": params.get("host", "")},
        }
    elif network == "xhttp":
        settings["xhttpSettings"] = {
            "path": unquote(params.get("path", "/")),
            "host": params.get("host", ""),
            "mode": params.get("mode", "auto"),
        }
    return settings


def outbound_from_link(link: str) -> dict:
    url = urlparse(link)
    if url.scheme != "vless":
        raise SystemExit(f"unsupported scheme: {url.scheme}")
    params = {key: values[0] for key, values in parse_qs(url.query).items()}
    user = {"id": url.username, "encryption": params.get("encryption", "none"), "flow": params.get("flow", "")}
    return {
        "tag": "vpn",
        "protocol": "vless",
        "settings": {"vnext": [{"address": url.hostname, "port": url.port, "users": [user]}]},
        "streamSettings": stream_settings(params),
    }


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} '<vless://...>' <outbound.json>")
    link, target = sys.argv[1], sys.argv[2]
    config = {"outbounds": [outbound_from_link(link)]}
    os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
    with open(target, "w") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    os.chmod(target, 0o600)
    print(f"{target}: {config['outbounds'][0]['settings']['vnext'][0]['address']}")


if __name__ == "__main__":
    main()
