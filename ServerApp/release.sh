#!/bin/bash
# Run only with a Developer ID identity and a configured notarytool keychain profile.
set -euo pipefail
cd "$(dirname "$0")"
: "${ARCHIVEBOX_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
: "${ARCHIVEBOX_NOTARY_PROFILE:?Set your notarytool keychain profile name}"
: "${ARCHIVEBOX_BUILD_NUMBER:?Set an increasing integer build number}"
: "${ARCHIVEBOX_SPARKLE_PUBLIC_KEY:?Set the public key from Sparkle generate_keys}"
[[ "$ARCHIVEBOX_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'Build number must be a positive integer.' >&2; exit 1; }
bash build.sh
app="$PWD/dist/ArchiveBox Server.app"
zip="$PWD/dist/ArchiveBox-Server-arm64.zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$ARCHIVEBOX_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
spctl --assess --type execute "$app"
ditto -c -k --keepParent "$app" "$zip"
/usr/bin/shasum -a 256 "$zip" > "$zip.sha256"
# Sparkle signs the final notarized ZIP using the private key in Keychain.
# Versioned URLs keep published updates immutable; the small feed has a stable URL.
feed="$PWD/dist/server-$ARCHIVEBOX_BUILD_NUMBER"
mkdir -p "$feed"
cp "$zip" "$feed/ArchiveBox-Server-arm64.zip"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --download-url-prefix "https://github.com/ArchiveBox/ios-archivebox/releases/download/server-$ARCHIVEBOX_BUILD_NUMBER/" \
    "$feed"
printf 'Upload the ZIP to release server-%s; upload %s/appcast.xml to release server-updates.\n' "$ARCHIVEBOX_BUILD_NUMBER" "$feed"
printf 'Ready to attach to a GitHub release: %s\n' "$zip"
