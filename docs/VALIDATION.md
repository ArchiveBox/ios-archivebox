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
