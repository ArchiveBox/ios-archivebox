#!/bin/bash
set -euo pipefail
: "${ASC_PRIVATE_KEY:?Set the testflight environment secrets first}"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${APPLE_TEAM_ID:?}" "${RUNNER_TEMP:?}"
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
trap 'rm -f "$ASC_KEY_PATH"' EXIT
# XcodeGen's committed plists have literal versions, so update every product here.
for plist in App/Info.plist ShareExtension/Info.plist SafariWebExtension/Info-iOS.plist MacApp/Info.plist MacShareExtension/Info.plist SafariWebExtension/Info-macOS.plist; do
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
        DEVELOPMENT_TEAM="$APPLE_TEAM_ID" -allowProvisioningUpdates \
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
