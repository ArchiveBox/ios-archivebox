# Acceptance evidence

Validated on 2026-09-16 using Xcode 27.0, an iPhone 18 Pro simulator running iOS 27.0, and isolated real ArchiveBox 0.9.35rc446 collections. The app deployment target is iOS 26; compatibility with the Xcode 26 SDK is checked by CI.

- Swift Testing: address normalization, IPv4/IPv6, known API/admin/web host alternatives, invalid address rejection, mixed-text URL extraction, deduplication, and non-web URL rejection.
- iOS app and embedded share extension: built and installed successfully.
- Real settings UI: server probe; rejection of an invalid key; acceptance of a real key; save to shared Keychain; persistence verified after terminating/relaunching the app.
- Real Safari share sheet: opened an example.com URL, selected ArchiveBox, reviewed the URL, tapped Save to ArchiveBox, and observed server-acceptance confirmation.
- Independent server database verification: the exact shared URL appeared in `core_snapshot`, ID `01a0ac689c38713494bf31e699b679da`.
- Real subdomain server: entering the base address found `http://api.archivebox.localhost:8948`. Invalid keys were rejected; a valid key submitted a link. A separate GET of the resulting crawl confirmed its stored URL.

The API integration uncovered and now handles ArchiveBox’s asynchronous snapshot creation: a successful add can initially return an empty `snapshot_ids` array with a persisted `crawl_id` and matching `queued_urls`. The app confirms that receipt rather than waiting for extraction.

No mock servers, intercepted requests, injected settings, simulated share hosts, or production credentials were used. The UI test uses public XCTest actions on the actual app and Safari. The server was initialized with the public ArchiveBox CLI, and API credentials were obtained through its auth API.

Not yet validated: physical-device local-network permissions, distribution provisioning/TestFlight, App Store review, and sharing from every third-party app. URL and plain-text item representations are supported, but arbitrary file/media archiving is outside scope.

![Connection settings](screenshots/settings.png)

The full settings → Safari share UI test also passed against the subdomain-mode server, including automatic correction from the base host to the API host.

## Native Mac, Safari packaging, and personas

- Signed native macOS app, share extension, and Safari Web Extension built with Xcode 27.0. Safari recognizes the bundled extension as ArchiveBox 3.3.2.
- Manually tested Mac config UI: normalized server URL, API key validation, live persona dropdown with `AppleAcceptance` and `Default`, and shared Keychain save.
- Used Safari’s real macOS File → Share → ArchiveBox sheet. It displayed the saved server and `AppleAcceptance`, submitted the URL, and showed “Sent to ArchiveBox.” Independent SQLite verification matched the URL and persona on crawl `01a0ac80c4a5755694ce8db5ac2a59be`.
- Live Swift API integration fetched both server personas and submitted with `AppleAcceptance`. The persisted crawl `01a0ac7cec1e770e9548c409cf9a2e02` references that persona.
- Updated iPhone UI flow selected the live persona, saved/reloaded configuration, and submitted through Safari. The persisted crawl `01a0ac835e7175e38d63f7c48ceb2d1f` references `AppleAcceptance`. An unsigned test build correctly failed shared-Keychain access; runtime tests require signing entitlements. A subsequent signed run completed all UI assertions but Xcode stalled finalizing its result while repeatedly resolving the package graph; a separate build/test invocation reproduced the report-finalization wait. A sample located the wait in XCTest’s `XCTCrashLogTracker.waitForPendingCrashlogs()`.
- Upstream WXT source is pinned and built without modifying the browser-extension checkout. Both Apple bundles contain the WXT assets and native connection-import handler.

The final iPhone flow uses the fully opened Apps list rather than the underlying horizontal share carousel. All assertions completed, including the visible selected persona and success receipt; crawl `01a0ac8d0590779ab506788ea7580012` independently confirms the exact URL and `AppleAcceptance`. The Xcode 27 runner’s pending-crash-log wait prevents calling the final UI test report green, even though the user-facing flow completed. No assertions were disabled or loosened.

Safari native-message import still needs an enabled-extension runtime check: Safari ignored automated clicks on its enable checkbox. No Safari security settings were bypassed. iPad and other iPhone form factors share adaptive views/targets but were not separately run. Only the already installed iPhone simulator was used for these expanded checks.

![Saved default persona and Safari setup](screenshots/persona.png)

GitHub Actions run [35162082842](https://github.com/ArchiveBox/ios-archivebox/actions/runs/35162082842) passed the pinned WXT build, five Swift tests, and builds of the iOS and macOS apps with both embedded extensions.
