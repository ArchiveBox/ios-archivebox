# ArchiveBox Server for macOS

The optional Apple-silicon/macOS 26+ companion to the main ArchiveBox app. It lives
in the same repository but builds independently and includes the full ArchiveBox
Linux image, Apple Container runtime, kernel, guest init, and SwiftTerm terminal.
The main iPhone/iPad/Mac client contains none of these large assets.

Open **ArchiveBox Server.app** to start your server. Its menu-bar archive icon opens
a native menu with server status, active downloads, CPU and RAM, followed by Add URL,
Open ArchiveBox, Admin, Settings, Pause/Unpause Archiving, and Shut Down Server & Quit.
Status refreshes when the menu opens, at most once every 30 seconds; there is no
background menu timer. CPU needs two samples. Pause uses ArchiveBox’s crawl controls;
unpause resumes all paused crawls without restarting sealed archives. Add URL and
Admin open in your default browser. Open ArchiveBox launches the installed client or
its App Store listing (subject to public release availability). There is no Dock icon.
Closing the window keeps the server running; Shut Down Server & Quit stops its container. Quitting the main client
does not stop the companion.

- Server: `http://archivebox.localhost:18080`
- API: `http://api.archivebox.localhost:18080`
- Collection: `~/Library/Application Support/ArchiveBox Server/data`
- Runtime: `~/Library/Application Support/ArchiveBox Server/runtime`
- Logs: `~/Library/Application Support/ArchiveBox Server/desktop.log`

On first launch, Settings is the only tab and focuses the built-in **Create your
first admin** form. ArchiveBox's passwordless internal `system` account does not
complete setup. Creating an active admin unlocks **Archive**, **Activity**, and
**Settings**, and signs both webviews in with a normal Django session scoped to the
admin host. Existing sessions persist in WebKit; expired sessions use Archive's
normal login page. Additional superusers can be created above the terminal.

Settings shows the server's actual BASE_URL, admin and API URLs with copy buttons,
plus its Tailscale DNS name (or IP) when connected. The Tailscale row is detection
only: the server remains bound to localhost, so remote access needs a proxy.
Shortcuts open the current machine's config editor, Personas, API Keys & Webhooks,
and Debug Logs inside Archive. The machine config editor syncs with ArchiveBox.conf.

The upper-right toolbar shows the current BASE_URL as selectable linked text;
click it to open your default browser. **HTTP, TLS, and DNS** provides BASE_URL and
SERVER_SECURITY_MODE fields. **Apply & Restart** validates and saves both using
ArchiveBox's config CLI, then recreates the container with the same data mount.
This also removes old environment overrides that would mask saved config values.
The `auto` choice stays automatic rather than becoming its currently derived mode.

BASE_URL is the advertised origin, not a bind-address or certificate installer.
The local listener stays at `127.0.0.1:18080`; configure DNS and a TLS/reverse proxy
separately for a custom public URL. Changing the admin hostname may require signing
in again. Embedded destinations refresh after applying the settings.

Activity shares Archive's cookie store and displays only the server's live-progress
component. The pinned image has `/progress.json` and an embedded admin component,
not a standalone `/live-progress/` page, so a small WebKit script removes the
surrounding admin page while preserving its existing component and polling code.

Account creation uses Django's user manager, validators and password hasher inside
the running container. Passwords travel through stdin and are not logged, placed
in process arguments, or stored by the app. You can also run
`archivebox manage createsuperuser` in the embedded terminal. The terminal uses the
image's normal entrypoint and a real PTY, so commands run as ArchiveBox's normal user.
Terminal input and output are not logged. Configure an API key in the main app for
native/Safari sharing. Local and remote keys remain separate in Keychain.

The collection survives application updates, quitting, and switching the client to
a remote server. No prototype data is migrated or reset. Port 18080 must be free.
Apple Container's service labels are global: another active installation must be
stopped before this one starts. The app does not take over someone else's runtime.

## Build

```sh
cd ServerApp
bash prepare.sh   # large downloads; build-machine step only
bash build.sh
```

For an existing verified preparation directory, use
`ARCHIVEBOX_SERVER_ASSETS=/absolute/path/to/prepared/assets bash build.sh`.
Build output is `dist/ArchiveBox Server.app`. The default local signature is ad-hoc,
for development on the build machine. It is **not a public downloadable release**.

Pinned components:

- Apple Container 1.4.1, Apple's signed installer, Apache-2.0.
- Guest init `ghcr.io/apple/containerization/vminit:0.45.0`.
- Kernel `vmlinux-6.18.35-197-debug`, recommended by that Container release,
  from Kata Containers 3.32.0. Linux is GPL-2.0; matching sources/configuration:
  <https://github.com/kata-containers/kata-containers/tree/3.32.0/tools/packaging/kernel>.
- ArchiveBox index `sha256:26cf885e6ea791df15147cad4e07cc390d552926108bfcb5b827da5ffe5aad96`,
  ARM64 manifest `sha256:af6b75a1bef801c4caa8c5661fece5a8fcff044b1e83da31b123f43ec677bbe8`.
- SwiftTerm 1.19.0, MIT.

Apple's and SwiftTerm's licenses are copied into the bundle. ArchiveBox and its
Linux packages retain their upstream licenses. Apple's `system start` may try to
fetch its guest init before the bundled image import; fully offline first launch
has not been verified.

## Publish the optional download

```sh
export ARCHIVEBOX_SIGNING_IDENTITY='Developer ID Application: ...'
export ARCHIVEBOX_NOTARY_PROFILE='your-existing-notarytool-profile'
bash release.sh
```

This signs our app (preserving Apple's nested runtime signatures), submits it for
notarization, staples the ticket, assesses it with Gatekeeper, and produces
`dist/ArchiveBox-Server-arm64.zip` plus a SHA-256 file. Attach the ZIP to a stable
GitHub release in **ArchiveBox/ios-archivebox**. The direct client reads GitHub's
asset digest, verifies the ZIP and the ArchiveBox signing team, and requires a
successful Gatekeeper assessment before installing into `~/Applications`.
It never strips quarantine or bypasses a security warning. Existing installations
are launched, not overwritten. Interrupted downloads remove only staging data.

The App Store client opens the release page for manual installation. The
`ArchiveBoxMacDirect` scheme uses the same client source with automatic download
support; archive it with ReleaseDirect. A separate distribution configuration is
necessary because the App Store requires a sandbox and restricts downloading
additional executable functionality. No new App Store listing is created.

## Live management acceptance check

With the installed companion running and no sign-in-capable admin yet, run from
this repository's root:

```sh
swiftc -parse-as-library ServerApp/Sources/Runtime.swift \
  ServerApp/Sources/Management.swift ServerApp/Tests/ManagementAcceptance.swift \
  -o /tmp/archivebox-management-acceptance
/tmp/archivebox-management-acceptance "$HOME/Applications/ArchiveBox Server.app"
```

This creates a randomly named temporary admin through the same management code,
checks password hashing/authentication, authenticated shortcut/progress responses,
validation failures and log exclusion, then removes that account and session.
It does not replace a visual check of onboarding, focus and the Activity webview.

To verify HTTP settings against a running companion (temporarily changes its URL
and security mode, restarts twice, and restores the original effective settings):

```sh
swiftc -parse-as-library ServerApp/Sources/Runtime.swift \
  ServerApp/Sources/Management.swift ServerApp/Tests/HTTPSettingsAcceptance.swift \
  -o /tmp/archivebox-http-settings-acceptance
/tmp/archivebox-http-settings-acceptance "$HOME/Applications/ArchiveBox Server.app"
```
