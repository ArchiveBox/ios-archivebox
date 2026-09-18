#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-}" in
    Management|HTTPSettings|Archiving|OpenCode|BrowserSession|ClientBrowser|ClientSettings|ConnectionCode|PersonaProfiles|PersonaDeletion|Tailscale|NetworkAccess|ReplayFormats) check="$1" ;;
    *) echo 'Usage: ServerApp/Tests/run.sh CHECK "/path/to/ArchiveBox Server.app" (ClientSettings takes the signed client app instead)' >&2; exit 2 ;;
esac
app="${2:?Pass the installed companion path}"
swift build --target ArchiveBoxCore
products="$(swift build --show-bin-path)"
mkdir -p .build/acceptance
client_sources=()
if [[ "$check" == ClientBrowser ]]; then client_sources+=(App/EmbeddedBrowser.swift); fi
if [[ "$check" == ClientSettings ]]; then
    client_sources+=(App/SettingsView.swift App/AppEnvironment.swift MacLocalUI/LocalServer.swift MacLocalUI/LocalServerSection.swift)
fi
swiftc -parse-as-library -target arm64-apple-macos26.0 -I "$products" "$products/ArchiveBoxCore.o" \
    ServerApp/Sources/Runtime.swift ServerApp/Sources/Management.swift ServerApp/Sources/NetworkAccess.swift ServerApp/Sources/BrowserProfiles.swift \
    "${client_sources[@]}" \
    "ServerApp/Tests/${check}Acceptance.swift" -o ".build/acceptance/$check"
if [[ "$check" == ClientSettings ]]; then
    # A real development app's profile is required to access the shared Keychain.
    : "${ARCHIVEBOX_SIGNING_IDENTITY:?Set the development signing identity for the client app}"
    bundle=$(mktemp -d "$PWD/.build/acceptance/client-settings.XXXXXX")/ArchiveBox.app
    trap 'rm -rf "$(dirname "$bundle")"' EXIT
    mkdir -p "$bundle/Contents/MacOS"
    cp "$app/Contents/Info.plist" "$app/Contents/embedded.provisionprofile" "$bundle/Contents/"
    cp ".build/acceptance/$check" "$bundle/Contents/MacOS/ArchiveBox"
    codesign -d --entitlements :- "$app" > "$bundle/../entitlements.plist" 2>/dev/null
    codesign --force --sign "$ARCHIVEBOX_SIGNING_IDENTITY" --entitlements "$bundle/../entitlements.plist" "$bundle"
    "$bundle/Contents/MacOS/ArchiveBox"
    exit
fi
if [[ -n "${ARCHIVEBOX_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --identifier io.archivebox.Server --sign "$ARCHIVEBOX_SIGNING_IDENTITY" ".build/acceptance/$check"
fi
".build/acceptance/$check" "$app" "${@:3}"
