#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-}" in
    Management|HTTPSettings|Archiving) check="$1" ;;
    *) echo 'Usage: ServerApp/Tests/run.sh Management|HTTPSettings|Archiving "/path/to/ArchiveBox Server.app"' >&2; exit 2 ;;
esac
app="${2:?Pass the installed companion path}"
swift build --target ArchiveBoxCore
products="$(swift build --show-bin-path)"
mkdir -p .build/acceptance
swiftc -parse-as-library -target arm64-apple-macos26.0 -I "$products" "$products/ArchiveBoxCore.o" \
    ServerApp/Sources/Runtime.swift ServerApp/Sources/Management.swift \
    "ServerApp/Tests/${check}Acceptance.swift" -o ".build/acceptance/$check"
".build/acceptance/$check" "$app"
