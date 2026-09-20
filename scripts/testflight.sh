#!/bin/bash
set -euo pipefail
: "${ASC_PRIVATE_KEY:?Set the testflight environment secrets first}"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${APPLE_TEAM_ID:?}" "${RUNNER_TEMP:?}"
: "${APPLE_DEVELOPMENT_P12:?Add the existing development signing identity to the testflight environment}"
: "${APPLE_DEVELOPMENT_PASSWORD:?}"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Invalid app version'; exit 1; }
[[ "$RELEASE_PLATFORM" =~ ^(both|iOS|macOS)$ ]] || { echo 'Invalid platform'; exit 1; }
# Reruns must not collide with a build still processing at Apple.
build_base="$((100 + GITHUB_RUN_NUMBER))"
if [[ -n "${RELEASE_REF:-}" ]]; then build_base=$(node -p 'require("./release.json").build'); fi
export RELEASE_BUILD="$build_base.${GITHUB_RUN_ATTEMPT}"
export ASC_KEY_PATH="$RUNNER_TEMP/ArchiveBox-AuthKey.p8"
previous_umask=$(umask)
umask 077
printf '%s' "$ASC_PRIVATE_KEY" > "$ASC_KEY_PATH"
unset ASC_PRIVATE_KEY
umask "$previous_umask"
# Reuse one development identity across ephemeral runners. Creating a new one
# on every archive eventually exhausts Apple's certificate quota; distribution
# signing still happens in Apple's cloud at export, as before.
credentials=$(mktemp -d "$RUNNER_TEMP/testflight-signing.XXXXXX")
keychain="$credentials/signing.keychain-db"
cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf "$credentials"
    rm -f "$ASC_KEY_PATH"
}
trap cleanup EXIT
(umask 077; printf '%s' "$APPLE_DEVELOPMENT_P12" | /usr/bin/base64 --decode > "$credentials/development.p12")
unset APPLE_DEVELOPMENT_P12
security create-keychain -p "$APPLE_DEVELOPMENT_PASSWORD" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$APPLE_DEVELOPMENT_PASSWORD" "$keychain"
security import "$credentials/development.p12" -k "$keychain" -P "$APPLE_DEVELOPMENT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$APPLE_DEVELOPMENT_PASSWORD" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Apple Development:/ {print $2; exit}')
[[ -n "$identity" ]] || { echo 'Apple Development identity missing' >&2; exit 1; }
# XcodeGen's committed plists have literal versions, so update every product here.
for plist in App/Info.plist ShareExtension/Info.plist SafariWebExtension/Info-iOS.plist MacApp/Info.plist MacShareExtension/Info.plist SafariWebExtension/Info-macOS.plist Widgets/Info-iOS.plist Widgets/Info-macOS.plist; do
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_BUILD" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$plist"
done
cat > "$RUNNER_TEMP/ArchiveBox-ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$APPLE_TEAM_ID</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>uploadSymbols</key><true/>
</dict></plist>
PLIST
for platform in iOS macOS; do
    [[ "$RELEASE_PLATFORM" == both || "$RELEASE_PLATFORM" == "$platform" ]] || continue
    scheme=ArchiveBox
    [[ "$platform" != macOS ]] || scheme=ArchiveBoxMac
    archive="$RUNNER_TEMP/$scheme.xcarchive"
    # Cloud signing at export keeps distribution private keys on Apple's servers.
    xcodebuild -project ArchiveBox.xcodeproj -scheme "$scheme" -configuration Release \
        -destination "generic/platform=$platform" -archivePath "$archive" \
        DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" archive
    # Both rsync processes must use Apple's version during export.
    PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$archive" \
        -exportPath "$RUNNER_TEMP/$scheme-export" \
        -exportOptionsPlist "$RUNNER_TEMP/ArchiveBox-ExportOptions.plist" \
        -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
done
node scripts/testflight-distribute.mjs
