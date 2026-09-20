#!/bin/bash
# Large payload belongs only in the optional companion, never the client bundle.
set -euo pipefail
cd "$(dirname "$0")"
# Hardened runtime requires a shared Team ID for the host and its framework.
# Ad-hoc signatures can verify successfully but still fail dyld library validation.
signing_identity="${ARCHIVEBOX_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2; exit}')}"
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
    echo 'Set ARCHIVEBOX_SIGNING_IDENTITY to an Apple Development or Developer ID Application identity; ad-hoc signing cannot load Sparkle.' >&2
    exit 1
fi
assets="${ARCHIVEBOX_SERVER_ASSETS:-$PWD}"
if [[ -z "${ARCHIVEBOX_SERVER_IMAGE:-}" ]]; then
    uv run --no-project python server-image.py resolve
fi
if ! uv run --no-project python server-image.py verify "$assets/payload/images.tar"; then
    bash prepare.sh
    assets="$PWD"
fi
app="${1:-$PWD/dist/ArchiveBox Server.app}"
case "$app" in
    "$HOME/Applications/"*|/Applications/*)
        echo 'Build into dist; use install-local.sh to safely update an installed companion.' >&2
        exit 1 ;;
esac
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ../LICENSE "$app/Contents/Resources/LICENSE"
bash prepare-network.sh
cp vendor/caddy/caddy "$app/Contents/Resources/caddy"
cp vendor/caddy/LICENSE "$app/Contents/Resources/CADDY-LICENSE"
codesign --force --options runtime --sign "$signing_identity" "$app/Contents/Resources/caddy"
ditto "$assets/vendor/package/Payload" "$app/Contents/Resources/runtime"
cp "$assets/payload/images.tar" "$assets/payload/vmlinux" "$app/Contents/Resources/"
cp "$assets/vendor/container/LICENSE" "$app/Contents/Resources/APPLE-CONTAINER-LICENSE"
swift build --build-system native --arch arm64 -c release -Xlinker -rpath -Xlinker @executable_path/../Frameworks
cp .build/release/ArchiveBoxServer "$app/Contents/MacOS/ArchiveBoxServer"
ditto .build/release/SwiftTerm_SwiftTerm.bundle "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp -f .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/SWIFTTERM-LICENSE"
sparkle="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
# Sign Sparkle's nested executable bundles from the inside out with our identity.
for component in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
    codesign --force --options runtime --sign "${signing_identity}" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/$component"
done
codesign --force --options runtime --sign "${signing_identity}" "$app/Contents/Frameworks/Sparkle.framework"
# Share the client's browser logos and branding with the companion's Clients section.
xcrun actool "$PWD/../App/Assets.xcassets" --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 --output-format human-readable-text
test -s "$app/Contents/Resources/Assets.car"
# Reuse the client's branding without depending on an Xcode client build.
iconset="$PWD/.build/ArchiveBox.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" ../App/Assets.xcassets/BrandLogo.imageset/ArchiveBox.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" ../App/Assets.xcassets/BrandLogo.imageset/ArchiveBox.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/ArchiveBox.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.archivebox.Server</string>
<key>CFBundleName</key><string>ArchiveBox Server</string>
<key>CFBundleExecutable</key><string>ArchiveBoxServer</string>
<key>CFBundleIconFile</key><string>ArchiveBox.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>SUFeedURL</key><string>https://github.com/ArchiveBox/ios-archivebox/releases/download/server-updates/appcast.xml</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Help your devices find this ArchiveBox server.</string>
<key>NSBonjourServices</key><array><string>_archivebox._tcp</string></array>
<key>NSAppDataUsageDescription</key><string>Discover browser profiles to import into ArchiveBox Personas. Browser folders are shared read-only with your local server.</string>
<key>NSAppTransportSecurity</key><dict>
<key>NSAllowsLocalNetworking</key><true/>
<key>NSAllowsArbitraryLoadsInWebContent</key><true/>
<key>NSExceptionDomains</key><dict><key>localhost</key><dict>
<key>NSIncludesSubdomains</key><true/>
<key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
</dict></dict></dict>
</dict></plist>
PLIST
uv run --no-project python bundle-metadata.py "$app"
# Preserve Apple's nested signatures; only sign our executable/bundle.
# Public downloads require Developer ID signing, notarization, and stapling.
codesign --force --options runtime --sign "${signing_identity}" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
