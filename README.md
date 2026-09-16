# ArchiveBox for iOS

A small native iPhone and iPad app for sending links directly to your own **ArchiveBox 0.9.x or later** server. Built with Swift 6, SwiftUI, and the system’s Liquid Glass controls. Requires iOS/iPadOS 26 or later and Xcode 26 or later.

## Use

1. Enter your server address and tap **Test server**. Pasted admin/API paths are removed; missing schemes default to HTTPS. The app probes the entered host, the corresponding `api.` host, and the base host. The working address is shown in the field. For an HTTP-only server, include `http://` explicitly.
2. Paste an administrator’s API key from ArchiveBox’s admin → API Tokens and tap **Test API key**.
3. Tap **Save**. The verified server/key pair is saved atomically in shared Keychain, accessible only while the device is unlocked.
4. From Safari or another app, share a web URL or text containing links. Choose **ArchiveBox**, review the destination, and tap **Save to ArchiveBox**. Keep the sheet open until **Sent to ArchiveBox** appears.

The share extension submits a JSON POST to `/api/v1/cli/add`. Success means the server accepted the submission, not that remote archiving has finished. There is **no local queue, offline storage, submission history, automatic retry, or background transfer**. If a request fails, the sheet reports the failure. A timeout can leave the outcome uncertain: check the server before sharing again.

Private servers require the device to be on the appropriate Wi-Fi or VPN. `localhost` on a physical phone refers to the phone, not your Mac. The simulator can use a server running on the Mac.

## Build

Open `ArchiveBox.xcodeproj`, select the **ArchiveBox** scheme, and run on an iOS 26+ simulator. The generated project is committed; XcodeGen is only needed when changing `project.yml`.

```sh
swift test
xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBox \
  -sdk iphonesimulator -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# After changing project.yml (XcodeGen 2.46+):
xcodegen generate
```

For a physical device or TestFlight, select your Apple Developer team for **both** targets. Register the app and extension bundle IDs and enable their matching Keychain Sharing entitlement. The share extension ID must remain prefixed by the app ID. Override `ARCHIVEBOX_KEYCHAIN_GROUP` consistently if your organization uses another shared group. No App Group is needed yet: all shared state fits in one Keychain item.

## Architecture and future Safari/macOS integration

- `Sources/ArchiveBoxCore`: UI-independent Swift package containing URL normalization, API discovery, token validation, submission, shared-link parsing, and secure configuration storage. Builds on iOS and macOS.
- `App`: native SwiftUI configuration UI. Standard Form, NavigationStack, system colors, Dynamic Type, and a glass toolbar action; glass stays on controls rather than behind form content.
- `ShareExtension`: thin UIKit extension host embedding SwiftUI; reads real `NSItemProvider` URL/plain-text attachments and posts directly through the shared client.
- `project.yml`: reproducible Xcode project and signing/entitlement configuration.

To combine this with the WXT Safari extension later, add a Safari Web Extension target to the containing app, bundle the WXT output there, and add a native messaging handler that calls this same Swift package and Keychain store. A macOS target can also reuse the package and adapt the settings view. Keep one owner for the configuration; do not mirror API keys into JavaScript storage. This repository has no dependency on WXT or the browser-extension repository.

## Connection behavior

Server discovery validates the ArchiveBox OpenAPI schema and required modern routes. Probes never include credentials. Authenticated calls use only the verified saved origin; redirects are rejected, including redirects of the token-validation JSON body. Cookies and persistent URL caches are disabled. Tokens are never placed in URLs or logs. The app never downgrades HTTPS to HTTP automatically and never bypasses certificate validation.

App Transport Security allows explicitly configured HTTP self-hosted servers because their domains are not known at build time. HTTPS remains the default. The app and extension declare the local-network purpose. Review this justification when submitting to the App Store.

## Real integration/UI verification

`ArchiveBoxUITests` configures the app through its UI, tests invalid and valid keys, relaunches to verify secure persistence, then shares from Safari through the real iOS share sheet. It needs a disposable **real** ArchiveBox 0.9+ server; it does not mock networking or seed the app’s settings.

Pass `ARCHIVEBOX_TEST_SERVER` and `ARCHIVEBOX_TEST_TOKEN` as Xcode build settings when running the UI scheme. Use an expendable token: Xcode test logs/results may contain test input. The suite creates an example.com snapshot with a unique acceptance query. Check the server’s snapshot API/database for that URL after the run.

```sh
xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBox \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  ARCHIVEBOX_TEST_SERVER=http://localhost:8947 \
  ARCHIVEBOX_TEST_TOKEN="$ARCHIVEBOX_TEST_TOKEN" test
```

CI builds the app and share extension and runs pure Swift tests. Physical-device networking, distribution signing, and App Store review are separate acceptance steps.

## Privacy

No analytics, trackers, or developer-operated service. The app sends shared URLs only to the configured ArchiveBox server. The server address and API key are stored in device-only Keychain; shared links remain in memory only for the lifetime of the share operation. The project includes a privacy manifest.

## License

MIT. See [LICENSE](LICENSE).

The standalone live API check also verifies host correction and persisted crawl contents:

```sh
ARCHIVEBOX_TEST_SERVER=http://archivebox.localhost:8948 \
ARCHIVEBOX_EXPECTED_SERVER=http://api.archivebox.localhost:8948 \
ARCHIVEBOX_TEST_TOKEN="$ARCHIVEBOX_TEST_TOKEN" swift run ArchiveBoxIntegration
```

See [acceptance evidence](docs/VALIDATION.md) for what has been verified and what remains device/distribution-specific.
