#!/bin/bash
# Large payload belongs only in the optional companion, never the client bundle.
set -euo pipefail
cd "$(dirname "$0")"
assets="${ARCHIVEBOX_SERVER_ASSETS:-$PWD}"
app="${1:-$PWD/dist/ArchiveBox Server.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$assets/vendor/package/Payload" "$app/Contents/Resources/runtime"
cp "$assets/payload/images.tar" "$assets/payload/vmlinux" "$app/Contents/Resources/"
cp "$assets/vendor/container/LICENSE" "$app/Contents/Resources/APPLE-CONTAINER-LICENSE"
swift build --build-system native -c release
cp .build/release/ArchiveBox "$app/Contents/MacOS/ArchiveBoxServer"
ditto .build/release/SwiftTerm_SwiftTerm.bundle "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp -f .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/SWIFTTERM-LICENSE"
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
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect to your local ArchiveBox server.</string>
<key>NSAppTransportSecurity</key><dict>
<key>NSAllowsLocalNetworking</key><true/>
<key>NSAllowsArbitraryLoadsInWebContent</key><true/>
<key>NSExceptionDomains</key><dict><key>localhost</key><dict>
<key>NSIncludesSubdomains</key><true/>
<key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
</dict></dict></dict>
</dict></plist>
PLIST
# Preserve Apple's nested signatures; only sign our executable/bundle.
# Public downloads require Developer ID signing, notarization, and stapling.
codesign --force --options runtime --sign "${ARCHIVEBOX_SIGNING_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
