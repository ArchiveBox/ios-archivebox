#!/bin/bash
# Build-machine preparation only. End users receive the completed app bundle.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p vendor payload
version=1.4.1
if [[ -z "${ARCHIVEBOX_SERVER_IMAGE:-}" ]]; then
    uv run --no-project python server-image.py resolve
fi
image="${ARCHIVEBOX_SERVER_IMAGE:-$(uv run --no-project python -c 'import json; print(json.load(open("payload/resolved-image.json"))["image"])')}"
if [[ ! -d vendor/package ]]; then
    curl -fL "https://github.com/apple/container/releases/download/$version/container-$version-installer-signed.pkg" -o vendor/container.pkg
    printf "%s  %s\n" c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4 vendor/container.pkg | /usr/bin/shasum -a 256 -c -
    pkgutil --check-signature vendor/container.pkg
    pkgutil --expand-full vendor/container.pkg vendor/package
fi
mkdir -p vendor/container
curl -fsSL "https://raw.githubusercontent.com/apple/container/$version/LICENSE" -o vendor/container/LICENSE
cli="$PWD/vendor/package/Payload/bin/container"
# The stock runtime uses shared launchd labels. Never take over another service.
if launchctl list com.apple.container.apiserver >/dev/null 2>&1; then
    echo 'An Apple Container service is registered. Stop it before preparing the bundle.' >&2
    exit 1
fi
trap '"$cli" system stop' EXIT
"$cli" system start --app-root "$PWD/.runtime" --install-root "$PWD/vendor/package/Payload" --enable-kernel-install
"$cli" image pull --arch arm64 "$image"
"$cli" image tag "$image" archivebox/archivebox:dev
"$cli" image pull --arch arm64 ghcr.io/apple/containerization/vminit:0.45.0
"$cli" image save --arch arm64 -o "$PWD/payload/images.tar" archivebox/archivebox:dev ghcr.io/apple/containerization/vminit:0.45.0
cp .runtime/kernels/vmlinux-6.18.35-197-debug payload/vmlinux
uv run --no-project python server-image.py verify "$PWD/payload/images.tar"
