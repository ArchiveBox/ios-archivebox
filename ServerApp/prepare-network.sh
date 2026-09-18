#!/bin/bash
# Pinned official Caddy distribution. No Homebrew dependency on users' Macs.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p vendor/caddy
if [[ ! -x vendor/caddy/caddy || "$(vendor/caddy/caddy version)" != v2.11.4* ]]; then
    curl -fL https://github.com/caddyserver/caddy/releases/download/v2.11.4/caddy_2.11.4_mac_arm64.tar.gz -o vendor/caddy.tar.gz
    printf '%s  %s\n' 9efb0af2d6cf09cfb5053c0e51721b9b3d4956d346234f39368d943d25a3c9a7 vendor/caddy.tar.gz | /usr/bin/shasum -a 256 -c -
    tar -xzf vendor/caddy.tar.gz -C vendor/caddy caddy LICENSE
fi
