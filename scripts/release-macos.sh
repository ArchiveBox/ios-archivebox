#!/bin/bash
set -euo pipefail
: "${DEVELOPER_ID_PROFILES:?}" "${DEVELOPER_ID_P12:?}" "${DEVELOPER_ID_PASSWORD:?}" "${SPARKLE_PRIVATE_KEY:?}" "${SPARKLE_PUBLIC_KEY:?}"
: "${ASC_PRIVATE_KEY:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${RUNNER_TEMP:?}"
credentials=$(mktemp -d "$RUNNER_TEMP/release-credentials.XXXXXX")
keychain="$credentials/signing.keychain-db"
cleanup() { security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$credentials"; }
trap cleanup EXIT
# Restrict credentials only, not the app files that every installing user must read.
(umask 077
 printf '%s' "$DEVELOPER_ID_P12" | /usr/bin/base64 --decode > "$credentials/signing.p12"
 printf '%s' "$ASC_PRIVATE_KEY" > "$credentials/AuthKey.p8"
 printf '%s' "$SPARKLE_PRIVATE_KEY" > "$credentials/sparkle.key")
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profiles"
printf '%s' "$DEVELOPER_ID_PROFILES" | /usr/bin/base64 --decode | tar -xzf - -C "$profiles"
unset DEVELOPER_ID_PROFILES DEVELOPER_ID_P12 ASC_PRIVATE_KEY SPARKLE_PRIVATE_KEY
security create-keychain -p "$DEVELOPER_ID_PASSWORD" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$DEVELOPER_ID_PASSWORD" "$keychain"
security import "$credentials/signing.p12" -k "$keychain" -P "$DEVELOPER_ID_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$DEVELOPER_ID_PASSWORD" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
export ARCHIVEBOX_SIGNING_IDENTITY
ARCHIVEBOX_SIGNING_IDENTITY=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2; exit}')
[[ -n "$ARCHIVEBOX_SIGNING_IDENTITY" ]] || { echo 'Developer ID Application identity missing'; exit 1; }
export ARCHIVEBOX_APP_VERSION ARCHIVEBOX_BUILD_NUMBER ARCHIVEBOX_SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY"
ARCHIVEBOX_APP_VERSION=$(node -p 'require("./release.json").version')
ARCHIVEBOX_BUILD_NUMBER=$(node -p 'require("./release.json").build')
for plist in MacApp/Info.plist MacShareExtension/Info.plist SafariWebExtension/Info-macOS.plist; do
 /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ARCHIVEBOX_APP_VERSION" "$plist"
 /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ARCHIVEBOX_BUILD_NUMBER" "$plist"
done
mkdir -p dist
xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBoxMacDirect -configuration ReleaseDirect \
 -destination 'generic/platform=macOS' -archivePath "$RUNNER_TEMP/ArchiveBox-direct.xcarchive" \
 DEVELOPMENT_TEAM=Q3VA4FKRSA -allowProvisioningUpdates \
 -authenticationKeyPath "$credentials/AuthKey.p8" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" archive
cat > "$credentials/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>method</key><string>developer-id</string><key>teamID</key><string>Q3VA4FKRSA</string><key>signingStyle</key><string>manual</string><key>signingCertificate</key><string>$ARCHIVEBOX_SIGNING_IDENTITY</string>
<key>provisioningProfiles</key><dict>
<key>io.archivebox.ArchiveBox</key><string>ArchiveBox GitHub Developer ID</string>
<key>io.archivebox.ArchiveBox.Share</key><string>ArchiveBox Share GitHub Developer ID</string>
<key>io.archivebox.ArchiveBox.Safari</key><string>ArchiveBox Safari GitHub Developer ID</string>
</dict></dict></plist>
PLIST
PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/ArchiveBox-direct.xcarchive" \
 -exportPath "$RUNNER_TEMP/ArchiveBox-direct" -exportOptionsPlist "$credentials/export.plist"
bash ServerApp/build.sh
for product in client server; do
 if [[ "$product" == client ]]; then app="$RUNNER_TEMP/ArchiveBox-direct/ArchiveBox.app"; zip="$PWD/dist/ArchiveBox.app.zip"
 else app="$PWD/ServerApp/dist/ArchiveBox Server.app"; zip="$PWD/dist/ArchiveBox.Server.app.zip"; fi
 codesign --verify --deep --strict "$app"
 codesign -dv "$app" 2>&1 | grep -F 'TeamIdentifier=Q3VA4FKRSA'
 [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$ARCHIVEBOX_APP_VERSION" ]]
 ditto -c -k --keepParent "$app" "$zip"
 xcrun notarytool submit "$zip" --key "$credentials/AuthKey.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --output-format json > "$credentials/$product-notary.json"
 if [[ "$(plutil -extract status raw "$credentials/$product-notary.json")" != Accepted ]]; then
  id=$(plutil -extract id raw "$credentials/$product-notary.json")
  xcrun notarytool log "$id" --key "$credentials/AuthKey.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
  exit 1
 fi
 xcrun stapler staple "$app"
 xcrun stapler validate "$app"
 spctl --assess --type execute "$app"
 ditto -c -k --keepParent "$app" "$zip"
 unzip -tq "$zip"
done
# Feed generation must see only the server archive, not the unrelated client app.
mkdir -p "$RUNNER_TEMP/server-appcast"
cp dist/ArchiveBox.Server.app.zip "$RUNNER_TEMP/server-appcast/"
ServerApp/.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
 --ed-key-file "$credentials/sparkle.key" \
 --download-url-prefix "https://github.com/ArchiveBox/ios-archivebox/releases/download/v$ARCHIVEBOX_APP_VERSION/" \
 "$RUNNER_TEMP/server-appcast"
cp "$RUNNER_TEMP/server-appcast/appcast.xml" dist/appcast.xml
