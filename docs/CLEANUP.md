# Native app cleanup — 2026-09-17

## Repository ownership

- `ios-archivebox` owns both native products: ArchiveBox.app (iOS/iPadOS/macOS) and ArchiveBox Server.app (macOS), their Swift code, share extensions, native Safari handler, Xcode project, signing and packaging.
- `archivebox-browser-extension` owns all browser behavior, WXT source and manifests. Apple packaging now copies its unmodified Safari build at `2e1323932ff7a5d02db756ed2ced6e41d413efa1`. The old Apple-side JavaScript patch and nested WXT checkout were removed.
- Safari still supports its own server/key pair or automatic use of the app connection. Browser and native share-sheet persona selections remain independent.

## Changes

- Shared process execution, Keychain operations, embedded-page presentation, browser installation guidance and authenticated progress requests live in ArchiveBoxCore. Native browser-setup buttons are SwiftUI; browser behavior remains in WXT.
- Client navigation, embedded browsing, Add URLs and sidebar progress have cohesive source files. Server settings state and runtime inspection were separated from views, and native menu construction was centralized.
- The companion now builds in Swift 6 mode with a checked Sendable runtime. Its executable is explicitly named ArchiveBoxServer.
- Removed pre-release configuration migration, container migration and obsolete response-format compatibility paths. HTTP settings restart the existing container instead of replacing it and discarding its writable layer.
- Preserved explanatory comments. Added cancellation checks after shared authentication: an obsolete page load must not cancel the current navigation. This fixed a blank iPhone webview found during verification.
- Removed approximately 4.7 GiB of obsolete build outputs and the nested extension checkout. Canonical client, companion and SwiftPM build directories remain.
- Uninstalled ArchiveBoxUITests-Runner from the booted iPhone simulator and removed its built app bundle and the obsolete companion executable. UI test source/targets remain available; they are not shipping products. No connected physical phone was available for removal there.

## Verification

- Eight Swift core tests passed, including real subprocess input/output, cancellation/reaping and isolated Keychain operations.
- Signed direct macOS, unsigned App Store macOS, iOS simulator and companion release builds passed. Companion packaging and deep/strict code-signature verification passed.
- Both iPhone sidebar/page-reselection and authenticated relaunch tests passed individually. Protected Users and snapshots pages rendered after login; no simulator downloads were needed.
- Real API acceptance verified invalid-key rejection, valid credentials, browser-session exchange, progress, persona listing and a submitted crawl with its selected persona.
- Real HTTP-settings acceptance verified invalid-input handling, persisted settings, restart without container replacement, the changed hostname responding, restoration of original settings and preservation of users.
- WXT TypeScript compilation and Safari/Chrome/Firefox builds passed. Native messaging permission is Safari-only. Bundled Safari resources match WXT output except for the included upstream license.
- The rebuilt Mac client was relaunched and visually checked: connected status and a full-height AI Agent webview, without a native detail title bar or bottom gap.

Companion native UI automation still fails in the desktop accessibility helper; this pass verifies its build, signature and real server operations, but does not claim a successful companion visual check. Browser-cookie capture and Safari/share-sheet submission were not repeated in this cleanup pass; earlier end-to-end evidence is recorded in VALIDATION.md. Later entries here supersede historical migration and packaging descriptions in that log.
