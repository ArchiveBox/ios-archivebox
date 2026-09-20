# Building and contributing

[← Back to ArchiveBox.app](../README.md)

## Build

Requires Xcode 27+ with Swift 6.4, Node.js 22+, and pnpm 10.33.2. Apps still deploy to iOS/macOS 26; the new Siri schemas are available on OS 27. Prepare the Safari resources before opening/building the committed project:

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

To run on Mac or a physical device, select your Apple Developer team for the app and its Share, Safari, and Widgets extension targets, or pass `DEVELOPMENT_TEAM=YOUR_TEAM_ID`. Register their bundle IDs. The app, Share, and Safari targets use the same `ARCHIVEBOX_KEYCHAIN_GROUP`; Widgets only opens the app and needs no credentials. No App Group is needed.

When updating an existing simulator installation, preserve its `ArchiveBoxKeychainGroup` value from the installed app's `Info.plist` by passing the same `ARCHIVEBOX_KEYCHAIN_GROUP` to `xcodebuild`. A build with a different group cannot read the existing saved connection, including from Safari's native handler. The unsigned build commands above check compilation; they do not preserve a previously configured team's Keychain group automatically.

Both platform apps use `io.archivebox.ArchiveBox`, with `.Share`, `.Safari`, and `.Widgets` extensions. This supports adding iOS and macOS to **one App Store Connect listing / universal purchase**; distribution signing and store submission remain release steps. iPhone/iPad layouts adapt to window size and orientation without model-specific code; unreleased hardware is not separately certified.

## Architecture

- `Sources/ArchiveBoxCore`: shared API discovery/submission, browser authentication/presentation, Keychain storage, process execution, links, and app information.
- `App`: client navigation (`MainView`), connection settings, Add URLs, sidebar status, and cached embedded pages (`EmbeddedBrowser`). Uses system forms, adaptive sidebar, glass controls, and native WebKit APIs.
- `App/ArchiveSearchView.swift`: native search through `ArchiveBoxClient`; opens results with the existing authenticated `PageSession`. `ArchiveRoute` is the credential-free link format shared by Siri, Spotlight, and Handoff. App entities resolve through the server, without a second bookmark database.
- `Widgets`: launcher widget and Search/Add controls. `OpenArchiveDestinationIntent` is compiled into the app and both WidgetKit extensions; foreground execution uses the same app navigation as the menu.
- `MacLocalUI`: client-only companion discovery/download UI.
- `ServerApp`: the independent menu-bar companion; runtime/management/inspection are separate from settings state and views. Both apps compile in Swift 6 mode.
- `ShareExtension`: shared SwiftUI sheet/model plus thin UIKit host.
- `MacShareExtension`: thin AppKit host for the same sheet/model.
- `SafariWebExtension`: native Swift messaging handler and Apple entitlements; generated WXT resources are ignored. The JavaScript reader lives only in the extension repo.
- `project.yml`: reproducible platform targets, entitlements, and bundle identifiers.

Native API requests stay on the verified origin; all redirects are rejected, including token-validation JSON bodies. The API client uses no persistent cookies/caches, tokens in URLs/logs, automatic HTTPS downgrade, or certificate-validation bypass. Embedded pages and sidebar activity share the in-memory browser session returned for the API key; browser cookies/storage are not persisted. ATS permits explicitly configured HTTP self-hosted servers; HTTPS is the default. Review this justification for App Store submission.

There are exactly two shipping apps: ArchiveBox and ArchiveBox Server. iOS/macOS
client targets and the direct-download scheme are platform/distribution variants,
not separate products. Share/Safari/Widgets targets are embedded extensions. `UITests`,
`Tests`, `IntegrationTests`, and `ServerApp/Tests` are verification code, never
bundled app entrypoints. Xcode may install an `ArchiveBoxUITests-Runner` during UI
testing; remove it afterward with `xcrun simctl uninstall DEVICE_ID io.archivebox.ArchiveBoxUITests.xctrunner`.

Canonical local outputs are `build` (iOS), `build-direct` (Mac client), `.build`
(Swift package checks), and `ServerApp/dist` (companion). Do not retain ad-hoc
`build-*` copies after their checks finish. Server payload/vendor directories are
prepared dependencies, not legacy builds or collection data.

## Verification

CI builds both apps and all three kinds of extension and runs Swift package tests. For a disposable **real** ArchiveBox server, create an `AppleAcceptance` persona using `archivebox persona create AppleAcceptance`, then run the iPhone UI test against an installed simulator:

```sh
xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBox \
  -destination 'platform=iOS Simulator,name=YOUR_INSTALLED_IPHONE' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ARCHIVEBOX_TEST_SERVER=http://localhost:8947 \
  ARCHIVEBOX_TEST_TOKEN="$ARCHIVEBOX_TEST_TOKEN" test
```

This tests Archive connection gating and the real admin login page, invalid/valid keys, the live persona picker, saved settings after relaunch, and Safari’s real system share sheet. For the Safari web extension capture path, first run `testEnableSafariExtensionThroughSettings`, enable **Save full-page screenshots locally** and **Upload to server** in the extension Configuration page, then run `testSafariCaptureWithScreenshotUpload`. It submits a unique example.com URL and requires the screenshot upload to succeed against the configured real server. The test launches ArchiveBox first so Xcode installs the current bundled extension before Safari opens it. Use an expendable key: Xcode test artifacts may contain test input. No network interception or seeded app settings.

```sh
ARCHIVEBOX_TEST_SERVER=http://localhost:8947 \
ARCHIVEBOX_EXPECTED_SERVER=http://localhost:8947 \
ARCHIVEBOX_TEST_PERSONA=AppleAcceptance \
ARCHIVEBOX_TEST_TOKEN="$ARCHIVEBOX_TEST_TOKEN" swift run ArchiveBoxIntegration
```

See [validation evidence](VALIDATION.md) for tested behavior and remaining release checks.
