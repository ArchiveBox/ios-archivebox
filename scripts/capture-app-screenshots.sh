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
  tcpdump_launcher_pid=
  tcpdump_pidfile=
  sample_daphne() {
    local phase=$1 server_data="${RUNNER_TEMP:-}/screenshot-server" pid command
    [[ "${GITHUB_ACTIONS:-}" == true && "${ARCHIVEBOX_TEST_SERVER:-}" =~ ^http://127[.]0[.]0[.]1:[0-9]+$ ]] || return 0
    pid=$(sed -nE "s/.*spawned: 'worker_daphne' with pid ([0-9]+).*/\1/p" "$server_data/logs/supervisord.log" 2>/dev/null | tail -1 || true)
    if [[ -z "$pid" ]]; then
      pid=$(sed -nE 's/.*Worker worker_daphne: started RUNNING \(pid ([0-9]+),.*/\1/p' "$server_data/server.log" 2>/dev/null | tail -1 || true)
    fi
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    command=$(ps -p "$pid" -o command= 2>/dev/null) || return 0
    [[ "$command" == *"-m daphne"* ]] || return 0
    # Native stacks can reveal SQLite/native blocking versus an idle reactor.
    # sample records no process environment, request headers, or payloads.
    sample "$pid" 1 10 -file "$output/daphne-$phase.sample.txt" > /dev/null 2>> "$output/daphne-sample-errors.log" || true
  }
  sample_screenshot_services() {
    [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
    local pid command sole_booted sampled=0
    # A rendered page can still fail when XCTest's screenshot RPC never replies.
    # Sample only system services for this disposable Simulator, not the app.
    pid=$(xcrun simctl spawn "$device_id" launchctl list 2>/dev/null | awk '$3 == "com.apple.testmanagerd" && $1 ~ /^[0-9]+$/ {print $1; exit}' || true)
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      command=$(ps -p "$pid" -o comm= 2>/dev/null || true)
      if [[ "$command" == */testmanagerd ]]; then
        sample "$pid" 1 10 -file "$output/testmanagerd-failure.sample.txt" > /dev/null 2>> "$output/screenshot-service-sample-errors.log" || true
      fi
    fi
    # Host render services cannot be mapped to a UDID by their argv. Only
    # inspect them when the selected Simulator is the sole booted device.
    sole_booted=$(xcrun simctl list devices booted -j | node -e '
      let input=""; process.stdin.on("data", data => input += data); process.stdin.on("end", () => {
        const devices=Object.values(JSON.parse(input).devices).flat();
        if (devices.length === 1) process.stdout.write(devices[0].udid);
      });' 2>/dev/null || true)
    [[ "$sole_booted" == "$device_id" ]] || return 0
    while read -r pid command; do
      case "$command" in
        */SimRenderServer|*/SimMetalHost)
          [[ "$pid" =~ ^[0-9]+$ ]] || continue
          sample "$pid" 1 10 -file "$output/$(basename "$command")-$pid-failure.sample.txt" > /dev/null 2>> "$output/screenshot-service-sample-errors.log" || true
          ((sampled+=1))
          ((sampled < 4)) || break
          ;;
      esac
    done < <(ps -A -o pid=,comm=)
    log show --last 2m --style compact --info \
      --predicate '(process == "SimRenderServer" OR process == "SimMetalHost") AND (eventMessage CONTAINS[c] "screenshot" OR eventMessage CONTAINS[c] "screen capture" OR eventMessage CONTAINS[c] "IOSurface")' \
      2>> "$output/screenshot-service-log-errors.log" | awk 'NR <= 200 {print substr($0, 1, 500)}' > "$output/host-screenshot-services.log" || true
  }
  collect_simulator_screenshot_log() {
    [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
    # Keep only screenshot metadata from this Simulator's system services.
    xcrun simctl spawn "$device_id" log show --last 2m --style compact --info \
      --predicate '(process == "testmanagerd" OR process == "backboardd") AND (eventMessage CONTAINS[c] "screenshot" OR eventMessage CONTAINS[c] "screen capture" OR eventMessage CONTAINS[c] "IOSurface")' \
      2>> "$output/screenshot-service-log-errors.log" | awk 'NR <= 200 {print substr($0, 1, 500)}' > "$output/simulator-screenshot-services.log" || true
  }
  stop_iphone_diagnostics() {
    if [[ -n "$tcpdump_pidfile" && -s "$tcpdump_pidfile" ]]; then
      tcpdump_pid=$(cat "$tcpdump_pidfile")
      if [[ "$tcpdump_pid" =~ ^[0-9]+$ ]] && ps -p "$tcpdump_pid" -o comm= | grep -Eq '(^|/)tcpdump$'; then
        sudo -n kill -INT "$tcpdump_pid" 2>/dev/null || true
      fi
      rm -f "$tcpdump_pidfile"
    fi
    if [[ -n "$tcpdump_launcher_pid" ]]; then
      wait "$tcpdump_launcher_pid" 2>/dev/null || true
      tcpdump_launcher_pid=
    fi
    if [[ -n "$sampler_pid" ]]; then
      kill "$sampler_pid" 2>/dev/null || true
      wait "$sampler_pid" 2>/dev/null || true
      sampler_pid=
    fi
  }
  sampler_pid=
  trap stop_iphone_diagnostics EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Keep a low-overhead record of simulator load while it boots and XCTest runs.
  # A post-failure process snapshot can be dominated by crash diagnostics.
  (
    sleep_pid=
    trap 'exit 0' TERM INT
    trap '[[ -z "$sleep_pid" ]] || kill "$sleep_pid" 2>/dev/null || true' EXIT
    while :; do
      date -u '+%Y-%m-%dT%H:%M:%SZ'
      uptime
      memory_pressure -Q || true
      sysctl vm.swapusage || true
      ps -A -o pid=,ppid=,state=,%cpu=,%mem=,comm= | sort -k4,4nr | sed -n '1,20p'
      sleep 15 &
      sleep_pid=$!
      wait "$sleep_pid" || exit 0
      sleep_pid=
    done
  ) > "$output/resource-samples.log" 2>&1 &
  sampler_pid=$!
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
if [[ "$platform" == iphone && "${GITHUB_ACTIONS:-}" == true &&
      "${ARCHIVEBOX_TEST_SERVER:-}" =~ ^http://127[.]0[.]0[.]1:([0-9]+)$ ]]; then
  # The disposable CI server is bound to this loopback port. Capture only the
  # IPv4/TCP base headers, never HTTP payloads, to locate a stalled request.
  tcpdump_port=${BASH_REMATCH[1]}
  tcpdump_pidfile="$output/tcpdump.pid"
  # The output is deliberately written by the unprivileged shell to this run's directory.
  # shellcheck disable=SC2024
  sudo -n sh -c 'printf "%s\n" "$$" > "$1"; exec /usr/sbin/tcpdump -i lo0 -y NULL -nn -tttt -q -l -s 44 "ip and tcp port $2"' \
    sh "$tcpdump_pidfile" "$tcpdump_port" > "$output/transport-metadata.log" 2>&1 &
  tcpdump_launcher_pid=$!
  # Give tcpdump a bounded chance to attach before the app makes its first request.
  for ((attempt=0; attempt<20; attempt++)); do
    if [[ -s "$tcpdump_pidfile" ]] && ps -p "$(cat "$tcpdump_pidfile")" -o comm= | grep -Eq '(^|/)tcpdump$'; then break; fi
    if ! kill -0 "$tcpdump_launcher_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
fi
if [[ "$platform" == iphone ]]; then sample_daphne start; fi
xcodebuild "${test_args[@]}" "$test_action" || {
    result=$?
    if [[ "$platform" == iphone ]]; then
      sample_daphne failure
      stop_iphone_diagnostics
      sample_screenshot_services
      collect_simulator_screenshot_log
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
if [[ "$platform" == iphone ]]; then
  stop_iphone_diagnostics
fi
xcrun xcresulttool export attachments --path "$output/Capture.xcresult" --output-path "$output/attachments"
if [[ "$platform" == iphone ]]; then
  rm -f "$output/transport-metadata.log" "$output"/daphne-*.sample.txt "$output/daphne-sample-errors.log"
fi
