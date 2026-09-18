#!/bin/bash
# Real headful XCTest capture. Run only on a disposable macOS CI runner.
set -euo pipefail
platform=${1:?Usage: capture-app-screenshots.sh iphone|ipad|macos OUTPUT_DIRECTORY smoke|full}
output=${2:-build/screenshots/$platform}
mode=${3:-smoke}
case "$mode" in
  smoke) method=testLaunchScreenshot ;;
  *) echo "Only hosted-runner smoke capture is implemented pending feasibility verification." >&2; exit 2 ;;
esac
mkdir -p "$output"
output=$(cd "$output" && pwd)
case "$platform" in
  macos)
    scheme=ArchiveBoxMacScreenshots
    destination='platform=macOS'
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
    ;;
  *) echo "Unknown platform: $platform" >&2; exit 2 ;;
esac
xcodebuild -project ArchiveBox.xcodeproj -scheme "$scheme" \
  -destination "$destination" -derivedDataPath "$output/DerivedData" \
  -resultBundlePath "$output/Capture.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:"$scheme/ArchiveBoxScreenshotTests/$method" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  ARCHIVEBOX_TEST_SERVER="${ARCHIVEBOX_TEST_SERVER:-}" \
  ARCHIVEBOX_TEST_TOKEN="${ARCHIVEBOX_TEST_TOKEN:-}" test
xcrun xcresulttool export attachments --path "$output/Capture.xcresult" --output-path "$output/attachments"
