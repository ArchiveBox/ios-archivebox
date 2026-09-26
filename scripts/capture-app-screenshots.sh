#!/bin/bash
# Real headful XCTest capture. Run only on a disposable macOS CI runner.
set -euo pipefail
platform=${1:?Usage: capture-app-screenshots.sh iphone|ipad|macos|server OUTPUT_DIRECTORY smoke|full|gallery|build}
output=${2:-build/screenshots/$platform}
mode=${3:-smoke}
case "$mode" in
  smoke) method=testLaunchScreenshot ;;
  full) method=testAllScreens ;;
  gallery) method=testGalleryScreens ;;
  build) [[ "$platform" == macos ]] || exit 2; method= ;;
  *) echo "Mode must be smoke, full, gallery, or build (macOS only)." >&2; exit 2 ;;
esac
project=ArchiveBox.xcodeproj
class=ArchiveBoxScreenshotTests
mkdir -p "$output"
output=$(cd "$output" && pwd)
signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)
if [[ "$platform" == iphone ]]; then
  # Keep a low-overhead record of simulator load while it boots and XCTest runs.
  # A post-failure process snapshot can be dominated by crash diagnostics.
  (
    sleep_pid=
    trap 'exit 0' TERM INT
    trap '[[ -z "$sleep_pid" ]] || kill "$sleep_pid" 2>/dev/null || true' EXIT
    while :; do
      date -u '+%Y-%m-%dT%H:%M:%SZ'
      uptime
      ps -A -o pid=,ppid=,state=,%cpu=,%mem=,comm= | sort -k4,4nr | sed -n '1,20p'
      sleep 15 &
      sleep_pid=$!
      wait "$sleep_pid" || exit 0
      sleep_pid=
    done
  ) > "$output/resource-samples.log" 2>&1 &
  sampler_pid=$!
  trap 'kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true' EXIT
fi
case "$platform" in

  macos|server)
    scheme=ArchiveBoxMacScreenshots
    destination='platform=macOS'
    if [[ "$platform" == macos && -n "${ARCHIVEBOX_MAC_APP:-}" ]]; then
      # Compile XCTest on the same stable macOS/Xcode that runs it. The full
      # signed app was built separately with its required SDK; do not rebuild it.
      test -d "$ARCHIVEBOX_MAC_APP"
      codesign --verify --deep --strict "$ARCHIVEBOX_MAC_APP"
      cp ScreenshotTests/project.yml ScreenshotTests/ArchiveBoxScreenshotTests.swift "$output/"
      xcodegen generate --spec "$output/project.yml"
      project="$output/ArchiveBoxScreenshots.xcodeproj"
    else
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
    if [[ "$platform" == server ]]; then
      export ARCHIVEBOX_SIGNING_IDENTITY="$identity"
      bash ServerApp/build.sh
      export ARCHIVEBOX_SERVER_APP="$PWD/ServerApp/dist/ArchiveBox Server.app"
      scheme=ArchiveBoxServerScreenshots
      class=ServerScreenshotTests
      xcodegen generate
    else
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
  ArchiveBoxMacWidgets:
    settings:
      base:
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: '$identity'
        DEVELOPMENT_TEAM: Q3VA4FKRSA
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
    fi
    fi
    ;;
  iphone|ipad)
    scheme=ArchiveBoxScreenshots
    if [[ "$platform" == iphone ]]; then device_prefix=iPhone; else device_prefix=iPad; fi
    device_id=$(xcrun simctl list devices available -j | DEVICE_PREFIX="$device_prefix" node -e '
      let input=""; process.stdin.on("data", data => input += data); process.stdin.on("end", () => {
        const runtimes=Object.entries(JSON.parse(input).devices)
          .filter(([runtime]) => Number(runtime.match(/iOS-(\d+)/)?.[1]) >= 26)
          .sort(([a], [b]) => b.localeCompare(a, undefined, { numeric: true }));
        const device=runtimes.flatMap(([runtime, devices])=>devices.map(device=>({...device, runtime})))
          .find(device=>device.name.startsWith(process.env.DEVICE_PREFIX));
        if (!device) throw new Error(`No iOS 26+ ${process.env.DEVICE_PREFIX} simulator available`);
        process.stdout.write(device.udid);
      });')
    destination="platform=iOS Simulator,id=$device_id"
    if [[ "$platform" == iphone && -n "${ARCHIVEBOX_IPHONE_APP:-}" ]]; then
      test -d "$ARCHIVEBOX_IPHONE_APP"
      cp ScreenshotTests/project.yml ScreenshotTests/ArchiveBoxScreenshotTests.swift "$output/"
      xcodegen generate --spec "$output/project.yml"
      project="$output/ArchiveBoxScreenshots.xcodeproj"
      scheme=ArchiveBoxIPhoneScreenshots
      # Compile XCTest before first-boot Simulator services compete for CPU.
      xcodebuild -project "$project" -scheme "$scheme" \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$output/DerivedData" \
        "${signing[@]}" \
        ARCHIVEBOX_TEST_SERVER="${ARCHIVEBOX_TEST_SERVER:-}" \
        ARCHIVEBOX_TEST_TOKEN="${ARCHIVEBOX_TEST_TOKEN:-}" build-for-testing
    fi
    # Wait for first-boot setup/data migration, not just the simulator's Booted state.
    xcrun simctl bootstatus "$device_id" -b
    if [[ "$platform" == iphone && -n "${ARCHIVEBOX_IPHONE_APP:-}" ]]; then
      xcrun simctl install "$device_id" "$ARCHIVEBOX_IPHONE_APP"
    fi
    ;;
  *) echo "Unknown platform: $platform" >&2; exit 2 ;;
esac
if [[ "$mode" == build ]]; then
  xcodebuild -project "$project" -scheme ArchiveBoxMac \
    -destination "$destination" -derivedDataPath "$output/DerivedData" \
    "${signing[@]}" build
  app="$output/DerivedData/Build/Products/Release/ArchiveBox.app"
  codesign --verify --deep --strict "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$output/ArchiveBox.app.zip"
  exit 0
fi
test_args=(-destination "$destination" -resultBundlePath "$output/Capture.xcresult"
  -parallel-testing-enabled NO -only-testing:"$scheme/$class/$method")
test_args=(-project "$project" -scheme "$scheme" -derivedDataPath "$output/DerivedData"
  "${test_args[@]}" "${signing[@]}"
  ARCHIVEBOX_MAC_APP="${ARCHIVEBOX_MAC_APP:-}"
  ARCHIVEBOX_SERVER_APP="${ARCHIVEBOX_SERVER_APP:-}"
  ARCHIVEBOX_TEST_SERVER="${ARCHIVEBOX_TEST_SERVER:-}"
  ARCHIVEBOX_TEST_TOKEN="${ARCHIVEBOX_TEST_TOKEN:-}")
if [[ "$platform" == iphone && -n "${ARCHIVEBOX_IPHONE_APP:-}" ]]; then
  # Keep the xcresult and screenshot attachments, but avoid a ten-minute
  # simulator sysdiagnose after a failed UI assertion on CI.
  test_args+=(-collect-test-diagnostics never)
  test_action=test-without-building
else
  test_action=test
fi
xcodebuild "${test_args[@]}" "$test_action" || {
    result=$?
    if [[ "$platform" == iphone ]]; then
      # Include the connection checks that precede WebKit loading as well as
      # its navigation policy. These prefixes contain only phase/state metadata;
      # do not broaden this to arbitrary app logs that may contain URLs or keys.
      xcrun simctl spawn "$device_id" log show --last 5m --style compact --info \
        --predicate 'process == "ArchiveBox" AND (eventMessage CONTAINS "ArchiveBox page navigation " OR eventMessage CONTAINS "ArchiveBox connection validation " OR eventMessage CONTAINS "ArchiveBox navigation policy:")' \
        > "$output/page-navigation.log" 2>&1 || true
      if ! grep -Eq 'ArchiveBox (page navigation |connection validation |navigation policy:)' "$output/page-navigation.log"; then
        echo "No connection or navigation phase markers were found in the Simulator log." >&2
      fi
      cat "$output/page-navigation.log"
    fi
    # Distinguish an app assertion from a stopped server or an exhausted runner.
    uptime
    sysctl hw.memsize hw.ncpu
    sysctl vm.swapusage
    memory_pressure -Q || true
    ps -A -o pid,ppid,%cpu,%mem,comm | sort -nr -k3 | head -20 || true
    if [[ -n "${ARCHIVEBOX_TEST_SERVER:-}" ]]; then
      curl --fail --silent --show-error --max-time 15 \
        "$ARCHIVEBOX_TEST_SERVER/api/v1/openapi.json" -o /dev/null || true
    fi
    exit "$result"
  }
xcrun xcresulttool export attachments --path "$output/Capture.xcresult" --output-path "$output/attachments"
