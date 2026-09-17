#!/bin/bash
# Run only with a Developer ID identity and a configured notarytool keychain profile.
set -euo pipefail
cd "$(dirname "$0")"
: "${ARCHIVEBOX_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
: "${ARCHIVEBOX_NOTARY_PROFILE:?Set your notarytool keychain profile name}"
bash build.sh
app="$PWD/dist/ArchiveBox Server.app"
zip="$PWD/dist/ArchiveBox-Server-arm64.zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$ARCHIVEBOX_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
spctl --assess --type execute "$app"
ditto -c -k --keepParent "$app" "$zip"
/usr/bin/shasum -a 256 "$zip" > "$zip.sha256"
printf 'Ready to attach to a GitHub release: %s\n' "$zip"
