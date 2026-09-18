# First-run guide

The shared iOS/macOS client shows `App/SetupGuide.swift` before connection fields
on a fresh install. It explains saved copies, the server's storage role, and the
client/server relationship with a native diagram. Users can choose the Mac
companion, third-party hosting, Docker Compose, or the Python package.

Every page has a direct connection action. Choosing it remembers the skip in
`setupGuideDismissed`. Loading an existing saved connection also suppresses the
introduction, without waiting for network validation. A failed connection does
not bring the introduction back. Connection Settings can reopen the guide.
Notification permission is requested after API-key verification.

On Mac, **Set up on this Mac** selects the existing local companion workflow.
It does not download or launch a server by itself. The companion’s Network access section enables LAN and Tailscale listeners and
provides a Camera connection code; localhost always remains available.
Docker and Python commands follow the ArchiveBox `dev` README. Hosting links
come from that README, without fixed prices or a claim of tested compatibility;
users are told to confirm ArchiveBox 0.9+ and API-key support before paying.

**Reset app setup…** clears this device's active connection and Mac local/remote
profiles, returns to remote mode, and removes the introductory preference.
It requires confirmation in the app. It never deletes archive files, revokes
server-side keys, or removes server accounts.

## Validation, 2026-09-18

- Added a real UI regression test before implementation; it failed on the old
  app because the welcome screen did not exist.
- `FirstRunUITests/testIntroductionChoicesAndPersistentSkip` passed on disposable
  iPhone 17e and iPad mini simulators running iOS 27: all four routes, Back,
  direct connection, persistent skip after relaunch, and reopening from Settings.
- The same test passed with the iPhone's system content size set to
  `accessibility-extra-large`. No app preferences or connections were seeded.
- Reviewed actual iPhone/iPad screenshots. A footer overlap found during the
  initial run was fixed by giving the scroll view and footer separate layout space.
- The signed `ArchiveBoxMacDirect` DebugDirect build passed. Installed it at
  `/Applications/ArchiveBox.app`, verified its deep/strict signature, and launched
  the actual app. The native Mac setup screens were inspected through accessibility
  and a screenshot. The previous app is backed up in `/tmp/archivebox-before-setup.t97Np5`.
- This verifies the guide and navigation, not fresh server installations through
  every documented provider, physical iOS devices, or all accessibility settings.

Run the UI test on a fresh disposable simulator with the `ArchiveBox` scheme and
`-only-testing:ArchiveBoxUITests/FirstRunUITests`. Existing connection/share and
screenshot tests use the real **I already have a server** button on fresh installs.

## Network setup validation

Real localhost, LAN and Tailscale HTTP API discovery, API-key authentication and
browser sessions passed against the installed server. Independent listener toggles
were checked with real sockets. A regression reproduced the invalid `testserver`
native sign-in hostname and passed after management URL derivation was corrected.
The iPhone simulator discovered the advertised Tailscale IP, connected to the API,
and navigated the client/server and wildcard guides. These checks do not establish
physical-device connectivity, public internet access, or every replay format.
ArchiveWeb.page HTTP safe-mode replay remains under investigation: its existing
service-worker viewer requires a secure browser context.

The updated QR includes the Mac's existing administrator key. Real QR decoding,
Tailscale API authentication and browser-session exchange passed; the user also
confirmed Camera scan-and-sign-in on their physical iPhone. Keys are verified and
saved in Keychain, and never included in the QR's accessibility label or toolbar
address copy. A configured client asks before replacing its connection.

The companion's automatic network mode deliberately selects
`safe-onedomain-nojsreplay` with an empty BASE_URL. ArchiveBox 0.9.35rc486 suppresses
the duplicate web setup wizard and missing-URL warning for this configuration.
Real HTTP tests cover anonymous login and authenticated admin pages through
localhost aliases, LAN and Tailscale host addresses. Network selection remains
in the companion's settings; archived scripts remain blocked.
