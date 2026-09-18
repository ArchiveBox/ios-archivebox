#!/bin/bash
# Real headful XCTest capture. Run only on a disposable macOS CI runner.
set -euo pipefail
platform=${1:?Usage: capture-app-screenshots.sh iphone|ipad|macos OUTPUT_DIRECTORY smoke|full}
output=${2:-build/screenshots/$platform}
mode=${3:-smoke}
case "$mode" in
  smoke) method=testLaunchScreenshot ;;
  full) method=testAllScreens ;;
  *) echo "Mode must be smoke or full." >&2; exit 2 ;;
esac
mkdir -p "$output"
output=$(cd "$output" && pwd)
signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)
case "$platform" in

  macos)
    scheme=ArchiveBoxMacScreenshots
    destination='platform=macOS'
    : "${DEVELOPER_ID_PROFILES:?}" "${DEVELOPER_ID_P12:?}" "${DEVELOPER_ID_PASSWORD:?}" "${RUNNER_TEMP:?}"
    credentials=$(mktemp -d "$RUNNER_TEMP/screenshot-credentials.XXXXXX")
    keychain="$credentials/signing.keychain-db"
    signing_spec=$(mktemp "$PWD/.screenshot-signing.XXXXXX.yml")
    cleanup() {
      security delete-keychain "$keychain" >/dev/null 2>&1 || true
      rm -rf "$credentials"
      rm -f "$signing_spec"
    }
    trap cleanup EXIT
    (umask 077; printf '%s' "$DEVELOPER_ID_P12" | /usr/bin/base64 --decode > "$credentials/signing.p12")
    profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    mkdir -p "$profiles"
    printf '%s' "$DEVELOPER_ID_PROFILES" | /usr/bin/base64 --decode | tar -xzf - -C "$profiles"
    unset DEVELOPER_ID_PROFILES DEVELOPER_ID_P12
    security create-keychain -p "$DEVELOPER_ID_PASSWORD" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$DEVELOPER_ID_PASSWORD" "$keychain"
    security import "$credentials/signing.p12" -k "$keychain" -P "$DEVELOPER_ID_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$DEVELOPER_ID_PASSWORD" "$keychain" >/dev/null
    security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
    identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2; exit}')
    [[ -n "$identity" ]] || { echo 'Developer ID Application identity missing' >&2; exit 1; }
    # Override signing only in the disposable CI project. Shipping entitlements remain intact.
    cat > "$signing_spec" <<YAML
include: project.yml
targets:
  ArchiveBoxMac:
    settings:
      base:
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: '$identity'
        DEVELOPMENT_TEAM: Q3VA4FKRSA
        PROVISIONING_PROFILE_SPECIFIER: ArchiveBox GitHub Developer ID
  ArchiveBoxMacShare:
    settings:
      base:
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: '$identity'
        DEVELOPMENT_TEAM: Q3VA4FKRSA
        PROVISIONING_PROFILE_SPECIFIER: ArchiveBox Share GitHub Developer ID
  ArchiveBoxMacSafari:
    settings:
      base:
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: '$identity'
        DEVELOPMENT_TEAM: Q3VA4FKRSA
        PROVISIONING_PROFILE_SPECIFIER: ArchiveBox Safari GitHub Developer ID
  ArchiveBoxMacScreenshots:
    settings:
      base:
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: '-'
        CODE_SIGNING_REQUIRED: NO
        DEVELOPMENT_TEAM: ''
schemes:
  ArchiveBoxMacScreenshots:
    test:
      config: Release
YAML
    xcodegen generate --spec "$signing_spec"
    signing=(-configuration Release)
    ;;
  iphone|ipad)
    scheme=ArchiveBoxScreenshots
    if [[ "$platform" == iphone ]]; then device_prefix=iPhone; else device_prefix=iPad; fi
    device_id=$(xcrun simctl list devices available -j | DEVICE_PREFIX="$device_prefix" node -e '
      let input=""; process.stdin.on("data", data => input += data); process.stdin.on("end", () => {
        const runtimes=Object.entries(JSON.parse(input).devices).filter(([runtime]) => runtime.includes("iOS-26"));
        const device=runtimes.flatMap(([, devices])=>devices).find(device=>device.name.startsWith(process.env.DEVICE_PREFIX));
        if (!device) throw new Error(`No iOS 26 ${process.env.DEVICE_PREFIX} simulator available`);
        process.stdout.write(device.udid);
      });')
    destination="platform=iOS Simulator,id=$device_id"
    # Wait for first-boot setup/data migration, not just the simulator's Booted state.
    xcrun simctl bootstatus "$device_id" -b
    ;;
  *) echo "Unknown platform: $platform" >&2; exit 2 ;;
esac
xcodebuild -project ArchiveBox.xcodeproj -scheme "$scheme" \
  -destination "$destination" -derivedDataPath "$output/DerivedData" \
  -resultBundlePath "$output/Capture.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:"$scheme/ArchiveBoxScreenshotTests/$method" \
  "${signing[@]}" \
  ARCHIVEBOX_TEST_SERVER="${ARCHIVEBOX_TEST_SERVER:-}" \
  ARCHIVEBOX_TEST_TOKEN="${ARCHIVEBOX_TEST_TOKEN:-}" test || {
    result=$?
    # Distinguish an app assertion from a stopped server or an exhausted runner.
    uptime
    sysctl vm.swapusage
    ps -A -o pid,ppid,%cpu,%mem,comm | sort -nr -k3 | head -20 || true
    if [[ -n "${ARCHIVEBOX_TEST_SERVER:-}" ]]; then
      curl --fail --silent --show-error --max-time 15 \
        "$ARCHIVEBOX_TEST_SERVER/api/v1/openapi.json" -o /dev/null || true
    fi
    exit "$result"
  }
xcrun xcresulttool export attachments --path "$output/Capture.xcresult" --output-path "$output/attachments"
