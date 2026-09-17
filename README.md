# ArchiveBox for Apple devices

A small SwiftUI app for iPhone, iPad, and Mac: configure your **ArchiveBox 0.9.x+** server, browse its admin UI, and save links through the system share sheet. Uses Swift 6 and standard Liquid Glass controls on iOS/iPadOS/macOS 26+. The same project also bundles the existing WXT Safari extension.

## Use

The app opens in **Settings** (gear). **Archive** (building with columns) becomes available after **Test server** successfully connects. It embeds the server’s `/admin/` UI and follows its admin-host redirect when needed. Sign in using your normal server account; the API key is not a web login. Switching screens preserves the current page. Editing the server locks Archive until you connect again. Navigation adapts from a tab bar to a sidebar on larger screens.

1. Enter your server address and select **Test server**. Pasted admin/API paths are removed; missing schemes default to HTTPS. The app probes the entered host, its `api.` host, and the base host without sending credentials. The working address appears in the field. Include `http://` explicitly for an HTTP-only server.
2. Enter an administrator’s API key from ArchiveBox’s admin → API Tokens and select **Test API key**.
3. Choose a **Default persona** from the live server list, or leave **Server default** to use `Default`. **Refresh personas** reloads the list. Servers without the persona-list endpoint can still use Server default.
4. Select **Save**. The connection and persona are saved together in device-only Keychain.
5. Share a URL from Safari or another app, choose **ArchiveBox**, review the server and persona, and select **Save to ArchiveBox**. Keep the sheet open until **Sent to ArchiveBox** appears.

On Mac, enable ArchiveBox under System Settings → General → Login Items & Extensions → Extensions → ArchiveBox → Sharing if it does not appear in the share menu.

The native share extensions POST directly to `/api/v1/cli/add`. Success means the server accepted the URL, not that archiving has finished. There is **no native local queue, offline saving, submission history, automatic retry, or background transfer**. After a timeout, check the server before sharing again. Explicit personas are checked before submission so a deleted persona is not silently recreated by the server.

Private servers require the device’s Wi-Fi or VPN connection. `localhost` on a physical phone refers to the phone; the iPhone simulator can reach a server on the Mac.

## Browser extensions

Settings includes Safari, Chrome, Brave, Firefox, and Source Code shortcuts. Safari
opens its extension settings on macOS and iOS 26.2+; earlier iOS versions show the
manual setup path. Brave uses the Chrome Web Store listing. Only bundled Safari
shares the native app connection automatically; configure other browsers separately.
Browser/GitHub SVG marks are from Font Awesome Free 6.7.2 (CC BY 4.0; see
`App/Assets.xcassets/Browser-Icons-LICENSE.txt`).

### Safari extension

Enable ArchiveBox in Safari’s Extensions settings (on iOS: Settings → Apps → Safari → Extensions). Safari automatically reads the server and API key saved in the native app whenever it loads settings or saves a URL. Configure and save changes in the app; there is no import button or separate Safari connection to maintain. The native default persona applies to the system share sheet; the browser extension retains its own persona controls and existing behavior.

Apple packaging lives entirely here. `scripts/prepare-safari.mjs` builds a pinned revision of [archivebox-browser-extension](https://github.com/ArchiveBox/archivebox-browser-extension) in an ignored build directory. A small checked build patch connects its settings reader to native messaging and makes connection fields read-only. The upstream repository is unchanged and remains extension-focused.

The native app, share extension, and Safari native handler share one Keychain access group. Safari reads the current connection through its native handler without persisting a second copy of the token. Missing or locked app settings stop the operation instead of falling back to old browser credentials.

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
- `App`: shared SwiftUI Settings/Archive screens, using system forms, adaptive tabs/sidebar, glass controls, and the native WebKit `WebView`/`WebPage` APIs.
- `ShareExtension`: shared SwiftUI sheet/model plus thin UIKit host.
- `MacShareExtension`: thin AppKit host for the same sheet/model.
- `SafariWebExtension`: native messaging handler and automatic connection reader; generated WXT resources are ignored.
- `project.yml`: reproducible platform targets, entitlements, and bundle identifiers.

Native API requests stay on the verified origin; all redirects are rejected, including token-validation JSON bodies. The API client uses no persistent cookies/caches, tokens in URLs/logs, automatic HTTPS downgrade, or certificate-validation bypass. The Archive web view uses normal website navigation and persistent WebKit cookies/storage, separately from the native API key. ATS permits explicitly configured HTTP self-hosted servers; HTTPS is the default. Review this justification for App Store submission.

## Verification

CI builds both apps and both kinds of extension and runs Swift package tests. For a disposable **real** ArchiveBox server, create an `AppleAcceptance` persona using `archivebox persona create AppleAcceptance`, then run the iPhone UI test against an installed simulator:

```sh
xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBox \
  -destination 'platform=iOS Simulator,name=YOUR_INSTALLED_IPHONE' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ARCHIVEBOX_TEST_SERVER=http://localhost:8947 \
  ARCHIVEBOX_TEST_TOKEN="$ARCHIVEBOX_TEST_TOKEN" test
```

This tests Archive connection gating and the real admin login page, invalid/valid keys, the live persona picker, saved settings after relaunch, and Safari’s real system share sheet. Use an expendable key: Xcode test artifacts may contain test input. No network interception or seeded app settings.

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

## Optional local server on Mac

Choose **This Mac → Run server locally** in Settings to launch the separate
**ArchiveBox Server.app** companion. It runs in the menu bar and provides its own
Archive web view, Settings, live CPU/RAM/collection size, and SwiftTerm terminal.
Local and remote connections keep separate credentials; switching does not delete
collections. Create your local account and API key through ArchiveBox's normal UI.

The companion contains the large Linux runtime/image. It is never bundled in the
main client or downloaded on ordinary app launch. The direct Mac build downloads
it only after the button is clicked; the App Store build opens its download page
for manual installation. Automatic download requires a published, signed and
notarized companion release. See [ServerApp](ServerApp/README.md) for development,
storage, packaging, and release instructions. iOS/iPadOS remain remote clients.
