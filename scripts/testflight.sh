#!/bin/bash
# Local and CI releases use Apple Development for the intermediate archive, then
# app-store-connect export replaces executable signatures/profiles for distribution.
# TestFlight and public App Store builds use this same signing setup; public App
# Review is separate. Developer ID downloads use release-macos.sh instead.
# Requires a development private key (login keychain or CI's encrypted P12) and
# an ASC API key authorized for cloud distribution signing. See docs/TESTFLIGHT.md.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
export APPLE_TEAM_ID="${APPLE_TEAM_ID:-Q3VA4FKRSA}"
export RELEASE_VERSION="${RELEASE_VERSION:-$(node -p 'require("./release.json").version')}"
export RELEASE_PLATFORM="${RELEASE_PLATFORM:-both}"
export ASC_APP_ID="${ASC_APP_ID:-6769185501}"
export ASC_GROUP_ID="${ASC_GROUP_ID:-b81f9549-9f73-4e34-8204-14589fd2f58a}"
command -v uv >/dev/null
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Invalid app version'; exit 1; }
[[ "$RELEASE_PLATFORM" =~ ^(both|iOS|macOS)$ ]] || { echo 'Invalid platform'; exit 1; }
# Reruns must not collide with a build still processing at Apple.
if [[ -z "${RELEASE_BUILD:-}" ]]; then
    : "${GITHUB_RUN_NUMBER:?For local releases, set RELEASE_BUILD to a new Apple build number}"
    build_base="$((100 + GITHUB_RUN_NUMBER))"
    if [[ -n "${RELEASE_REF:-}" ]]; then build_base=$(node -p 'require("./release.json").build'); fi
    RELEASE_BUILD="$build_base.${GITHUB_RUN_ATTEMPT}"
fi
export RELEASE_BUILD
[[ "$RELEASE_BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo 'Invalid build number'; exit 1; }
mkdir -p "${RELEASE_OUTPUT_DIR:-$PWD/dist/testflight}"
output=$(mktemp -d "${RELEASE_OUTPUT_DIR:-$PWD/dist/testflight}/$RELEASE_VERSION-$RELEASE_BUILD.XXXXXX")
echo "Archives and verified exports: $output"
# Reuse one development identity across ephemeral runners. Creating a new one
# on every archive eventually exhausts Apple's certificate quota; distribution
# signing still happens in Apple's cloud at export, as before.
credentials=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/testflight-signing.XXXXXX")
keychain="$credentials/signing.keychain-db"
version_plists=(App/Info.plist ShareExtension/Info.plist SafariWebExtension/Info-iOS.plist MacApp/Info.plist MacShareExtension/Info.plist SafariWebExtension/Info-macOS.plist Widgets/Info-iOS.plist Widgets/Info-macOS.plist)
cleanup() {
    # A local invocation temporarily stamps all product versions. Restore exact
    # originals so publishing cannot leave version-only edits in the checkout.
    for plist in "${version_plists[@]}"; do
        if [[ -f "$credentials/originals/$plist" ]]; then
            cp "$credentials/originals/$plist" "$plist"
        fi
    done
    if [[ -f "$keychain" ]]; then
        security delete-keychain "$keychain" >/dev/null 2>&1 || true
        security list-keychains -d user -s "${previous_keychains[@]}"
    fi
    rm -rf "$credentials"
}
trap cleanup EXIT
if [[ -n "${ASC_PRIVATE_KEY:-}" ]]; then
    (umask 077; printf '%s' "$ASC_PRIVATE_KEY" > "$credentials/AuthKey_${ASC_KEY_ID}.p8")
else
    : "${ASC_KEY_PATH:?Set ASC_KEY_PATH to your App Store Connect .p8 file}"
    (umask 077; cat "$ASC_KEY_PATH" > "$credentials/AuthKey_${ASC_KEY_ID}.p8")
fi
unset ASC_PRIVATE_KEY
export ASC_KEY_PATH="$credentials/AuthKey_${ASC_KEY_ID}.p8"
if [[ -n "${APPLE_DEVELOPMENT_P12:-}" ]]; then
    # CI imports the existing private key; local developers may use their login
    # keychain instead. Preserve its search list rather than replacing user setup.
    : "${APPLE_DEVELOPMENT_PASSWORD:?}"
    previous_keychains=()
    while IFS= read -r item; do previous_keychains+=("$item"); done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')
    (umask 077; printf '%s' "$APPLE_DEVELOPMENT_P12" | /usr/bin/base64 --decode > "$credentials/development.p12")
    unset APPLE_DEVELOPMENT_P12
    security create-keychain -p "$APPLE_DEVELOPMENT_PASSWORD" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$APPLE_DEVELOPMENT_PASSWORD" "$keychain"
    security import "$credentials/development.p12" -k "$keychain" -P "$APPLE_DEVELOPMENT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$APPLE_DEVELOPMENT_PASSWORD" "$keychain" >/dev/null
    security list-keychains -d user -s "$keychain" "${previous_keychains[@]}"
    identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Apple Development:/ {print $2; exit}')
    [[ -n "$identity" ]] || { echo 'Apple Development identity missing' >&2; exit 1; }
fi
# XcodeGen's committed plists have literal versions, so update every product here.
for plist in "${version_plists[@]}"; do
    mkdir -p "$credentials/originals/$(dirname "$plist")"
    cp "$plist" "$credentials/originals/$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_BUILD" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$plist"
done
# Never use destination=upload here: Xcode can report EXPORT SUCCEEDED while
# Apple's later validation rejects a resource bundle signed by a different cert.
# Internal-testing-only exports cannot go to external testers or the App Store.
# Preserve our version/build pair so the API acceptance check identifies these
# exact bytes instead of an Xcode-renumbered or previously uploaded build.
cat > "$credentials/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>export</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$APPLE_TEAM_ID</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>testFlightInternalTestingOnly</key><false/>
<key>uploadSymbols</key><true/>
</dict></plist>
PLIST
for platform in iOS macOS; do
    [[ "$RELEASE_PLATFORM" == both || "$RELEASE_PLATFORM" == "$platform" ]] || continue
    scheme=ArchiveBox
    [[ "$platform" != macOS ]] || scheme=ArchiveBoxMac
    archive="$output/$scheme.xcarchive"
    # Development signing is intentional at archive time. Export replaces it on
    # executables; the project phase removes independent signatures only from
    # codeless package resources so no development signer leaks through export.
    # Cloud signing keeps distribution private keys on Apple's servers; the ASC
    # API key authorizes that operation but is not itself a code-signing key.
    xcodebuild -project ArchiveBox.xcodeproj -scheme "$scheme" -configuration Release \
        -destination "generic/platform=$platform" -archivePath "$archive" \
        DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" archive
    uv run scripts/verify-signing.py --mode development --team "$APPLE_TEAM_ID" "$archive"
    # Export without uploading so the actual distribution package is checked.
    # Both rsync processes must use Apple's version during export.
    PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$archive" \
        -exportPath "$output/$scheme-export" \
        -exportOptionsPlist "$credentials/ExportOptions.plist" \
        -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    packages=("$output/$scheme-export/"*.ipa "$output/$scheme-export/"*.pkg)
    package_count=0
    for package in "${packages[@]}"; do
        [[ -f "$package" ]] || continue
        package_count=$((package_count + 1))
        artifact="$package"
    done
    [[ "$package_count" == 1 ]] || { echo "Expected one export for $scheme" >&2; exit 1; }
    uv run scripts/verify-signing.py --mode app-store --team "$APPLE_TEAM_ID" "$artifact"
    # Apple's validation is additional to our offline checks, not a substitute.
    # Upload exactly the checked package; never rebuild/re-export between them.
    xcrun altool --validate-app "$artifact" --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"
    xcrun altool --upload-package "$artifact" --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"
done
# Upload success is only receipt of a delivery. Apple can reject it later (and
# email the owner), so require processing + group assignment for each platform.
node scripts/testflight-distribute.mjs
