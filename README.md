# ArchiveBox for Apple devices

A small SwiftUI app for iPhone, iPad, and Mac: configure your **ArchiveBox 0.9.x+** server and save links through the system share sheet. Uses Swift 6 and standard Liquid Glass controls on iOS/iPadOS/macOS 26+. The same project also bundles the existing WXT Safari extension.

## Use

1. Enter your server address and select **Test server**. Pasted admin/API paths are removed; missing schemes default to HTTPS. The app probes the entered host, its `api.` host, and the base host without sending credentials. The working address appears in the field. Include `http://` explicitly for an HTTP-only server.
2. Enter an administrator’s API key from ArchiveBox’s admin → API Tokens and select **Test API key**.
3. Choose a **Default persona** from the live server list, or leave **Server default** to use `Default`. **Refresh personas** reloads the list. Servers without the persona-list endpoint can still use Server default.
4. Select **Save**. The connection and persona are saved together in device-only Keychain.
5. Share a URL from Safari or another app, choose **ArchiveBox**, review the server and persona, and select **Save to ArchiveBox**. Keep the sheet open until **Sent to ArchiveBox** appears.

On Mac, enable ArchiveBox under System Settings → General → Login Items & Extensions → Extensions → ArchiveBox → Sharing if it does not appear in the share menu.

The native share extensions POST directly to `/api/v1/cli/add`. Success means the server accepted the URL, not that archiving has finished. There is **no native local queue, offline saving, submission history, automatic retry, or background transfer**. After a timeout, check the server before sharing again. Explicit personas are checked before submission so a deleted persona is not silently recreated by the server.

Private servers require the device’s Wi-Fi or VPN connection. `localhost` on a physical phone refers to the phone; the iPhone simulator can reach a server on the Mac.

## Safari extension

Enable ArchiveBox in Safari’s Extensions settings (on iOS: Settings → Apps → Safari → Extensions). In the extension popup/options, select **Use app connection** to import the native app’s saved server and API key. Repeat the import after changing them. The native default persona applies to the system share sheet; the browser extension retains its own persona controls and existing behavior.

Apple packaging lives entirely here. `scripts/prepare-safari.mjs` builds a pinned revision of [archivebox-browser-extension](https://github.com/ArchiveBox/archivebox-browser-extension) in an ignored build directory. It adds only native messaging permission and a small explicit connection-import button to the generated assets. The upstream repository is unchanged and remains extension-focused. There is no automatic two-way settings synchronization or fork of its application code.

The native app, share extension, and Safari native handler share one Keychain access group. Importing into Safari explicitly copies the server/key into the browser extension’s normal local settings storage, as required by its existing API client. Native sharing continues to use Keychain directly.

## Build

Requires Xcode 26+ with Swift 6.2, Node.js 22+, and pnpm 10.33.2. Prepare the Safari resources before opening/building the committed project:

```sh
node scripts/prepare-safari.mjs
swift test
xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBox \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBoxMac \
  -destination 'generic/platform=macOS' -derivedDataPath build-mac \
  CODE_SIGNING_ALLOWED=NO build
```

Select **ArchiveBox** for iPhone/iPad or **ArchiveBoxMac** for native Mac. The generated project is committed. After changing `project.yml`, run `xcodegen generate` (XcodeGen 2.46+) after preparing Safari resources.

To run on Mac or a physical device, select your Apple Developer team for the app and both extension targets, or pass `DEVELOPMENT_TEAM=YOUR_TEAM_ID`. Register their bundle IDs and matching Keychain Sharing entitlement. Use the same `ARCHIVEBOX_KEYCHAIN_GROUP` for all three targets. No App Group is needed.

Both platform apps use `io.archivebox.ArchiveBox`, with `.Share` and `.Safari` extensions. This supports adding iOS and macOS to **one App Store Connect listing / universal purchase**; distribution signing and store submission remain release steps. iPhone/iPad layouts adapt to window size and orientation without model-specific code; unreleased hardware is not separately certified.

## Architecture

- `Sources/ArchiveBoxCore`: shared API discovery, authentication, persona listing, submission, link parsing, and Keychain configuration.
- `App`: shared SwiftUI configuration, using system forms, colors, Dynamic Type, and glass controls.
- `ShareExtension`: shared SwiftUI sheet/model plus thin UIKit host.
- `MacShareExtension`: thin AppKit host for the same sheet/model.
- `SafariWebExtension`: native messaging handler and packaging-only connection-import UI; generated WXT resources are ignored.
- `project.yml`: reproducible platform targets, entitlements, and bundle identifiers.

Authenticated requests stay on the verified origin; all redirects are rejected, including token-validation JSON bodies. No persistent cookies/caches, tokens in URLs/logs, automatic HTTPS downgrade, or certificate-validation bypass. ATS permits explicitly configured HTTP self-hosted servers; HTTPS is the default. Review this justification for App Store submission.

## Verification

CI builds both apps and both kinds of extension and runs Swift package tests. For a disposable **real** ArchiveBox server, create an `AppleAcceptance` persona using `archivebox persona create AppleAcceptance`, then run the iPhone UI test against an installed simulator:

```sh
xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBox \
  -destination 'platform=iOS Simulator,name=YOUR_INSTALLED_IPHONE' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ARCHIVEBOX_TEST_SERVER=http://localhost:8947 \
  ARCHIVEBOX_TEST_TOKEN="$ARCHIVEBOX_TEST_TOKEN" test
```

This tests invalid/valid keys, the live persona picker, saved settings after relaunch, and Safari’s real system share sheet. Use an expendable key: Xcode test artifacts may contain test input. No network interception or seeded app settings.

```sh
ARCHIVEBOX_TEST_SERVER=http://localhost:8947 \
ARCHIVEBOX_EXPECTED_SERVER=http://localhost:8947 \
ARCHIVEBOX_TEST_PERSONA=AppleAcceptance \
ARCHIVEBOX_TEST_TOKEN="$ARCHIVEBOX_TEST_TOKEN" swift run ArchiveBoxIntegration
```

See [validation evidence](docs/VALIDATION.md) for tested behavior and remaining release checks.

## Privacy and license

No analytics, trackers, or developer-operated service. Shared URLs go to your configured ArchiveBox server. Native share links remain in memory for the operation only; configuration uses device-only Keychain. Safari’s upstream behavior/storage is separate as described above. A privacy manifest is included.

MIT. See [LICENSE](LICENSE) and [branding provenance](docs/BRANDING.md). The bundled upstream extension retains its own license; see `SafariWebExtension/UPSTREAM-LICENSE`.
