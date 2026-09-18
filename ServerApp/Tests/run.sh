#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-}" in
    Management|HTTPSettings|Archiving|OpenCode|BrowserSession|ConnectionCode|PersonaProfiles|PersonaDeletion|Tailscale|NetworkAccess|ReplayFormats) check="$1" ;;
    *) echo 'Usage: ServerApp/Tests/run.sh Management|HTTPSettings|Archiving|OpenCode|BrowserSession|ConnectionCode|PersonaProfiles|PersonaDeletion|Tailscale|NetworkAccess|ReplayFormats "/path/to/ArchiveBox Server.app"' >&2; exit 2 ;;
esac
app="${2:?Pass the installed companion path}"
swift build --target ArchiveBoxCore
products="$(swift build --show-bin-path)"
mkdir -p .build/acceptance
swiftc -parse-as-library -target arm64-apple-macos26.0 -I "$products" "$products/ArchiveBoxCore.o" \
    ServerApp/Sources/Runtime.swift ServerApp/Sources/Management.swift ServerApp/Sources/NetworkAccess.swift ServerApp/Sources/BrowserProfiles.swift \
    "ServerApp/Tests/${check}Acceptance.swift" -o ".build/acceptance/$check"
if [[ -n "${ARCHIVEBOX_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --identifier io.archivebox.Server --sign "$ARCHIVEBOX_SIGNING_IDENTITY" ".build/acceptance/$check"
fi
".build/acceptance/$check" "$app" "${@:3}"
