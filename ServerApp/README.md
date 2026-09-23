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
Admin use the browser or installed client as appropriate. Open ArchiveBox launches
the installed client, falling back to the web interface. There is no Dock icon.
Closing the window keeps the server running; Shut Down Server & Quit stops its container. Quitting the main client
does not stop the companion.

Once the server is ready and its first administrator exists, Settings offers
ArchiveBox.app. It detects the client in Applications or through Launch Services,
offers the Mac download and installation steps when missing, and rechecks when
you return to the server app or click **Check again**. **Open & Connect ArchiveBox.app**
passes this server's address and administrator key directly to the installed client,
which verifies the key and saves it in Keychain. **Not now** dismisses the suggestion
across launches; downloads and connection help remain available in **Clients**.

- Server: `http://archivebox.localhost:5797`
- API: `http://api.archivebox.localhost:5797`
- Collection: `~/Library/Application Support/ArchiveBox Server/data`
- Runtime: `~/Library/Application Support/ArchiveBox Server/runtime`
- Logs: `~/Library/Application Support/ArchiveBox Server/desktop.log`

The server automatically mounts existing Chrome, Chrome Beta, Chromium, and Brave profile
folders from your Mac's `~/Library/Application Support` read-only. On startup it
creates one private Persona per detected profile, exporting cookies with the macOS
Keychain and copying browser preferences automatically. No host CLI setup is needed.
Restart after adding a profile to import it. Imports copy into the collection; the original profiles are
never writable by the container. Allow the browser-data permissions requested by
macOS. If previously denied, enable the browser entries under **System Settings →
Privacy & Security → Files & Folders → ArchiveBox Server**, then restart the app.
Denied access is reported before replacing an existing server container.
Allow the browser's **Safe Storage** Keychain prompt as well. Decryption happens
inside the signed macOS app; the Keychain password never enters the container.
Completed imports are recorded in `.host-browser-personas.json` independently of
the database: deleting or renaming a Persona does not recreate it on later launches.
Existing Personas are never overwritten. Profile imports run after the server and
network connections are ready. A denied Keychain prompt or an unreadable cookie
shows a per-profile error and a retry button in Settings; other profiles continue.
**Personas → Add** can reuse the portable
exports in `.host-browser-profiles`, including after deleting a seeded Persona.
These are snapshots of cookies/preferences at import time, not a continuous sync of
browser history, saved passwords, or local storage. To refresh cookies or import
from another browser, use the [ArchiveBox browser extension](https://extension.archivebox.io/).

The bundled container always sets `OPENCODE_ENABLED=true`, including during
initialization. Each newly created server container resolves
the declared agent dependencies at runtime, without changing the bundled image. The client’s **AI Agent** screen
opens `/admin/agent/`. Configure a model/provider in OpenCode if required; its
credentials and sessions persist in the collection’s `opencode/` directory.

On first launch, Settings is the only tab and focuses the built-in **Create your
first admin** form. ArchiveBox's passwordless internal `system` account does not
complete setup. Creating an active admin unlocks **Admin**, **Activity**, **Shell**,
**Users**, and **Settings**, in that order, and signs both webviews in with a normal
Django session scoped to the admin host. The companion stores an API key for the first active administrator in Keychain, scoped to the collection. It uses the same `/api/v1/auth/browser_session` exchange as the iOS/macOS client; browser cookies stay in memory and login is restored after relaunch. Revoked keys produce an authentication error rather than silently selecting another account. Additional superusers can be created in **Users**. **Shell** keeps the same terminal
session and scrollback while switching tabs, and expands to fill the window.

**Network access** controls LAN and Tailscale separately; localhost is always
available. The bundled Caddy helper binds only selected interface addresses. The
default is HTTP on port 5797 with an automatic BASE_URL, so each device keeps
using the address it connected through. Automatic security selects
`safe-onedomain-nojsreplay`. Explicit BASE_URL and security overrides remain available.

Tailscale network access, Serve/Funnel and their setup actions stay visible but
are disabled when Tailscale is not installed. The section links to installation
and rechecks availability when you return to the app. LAN and custom-certificate
options remain available independently.

When Tailscale is connected, a guest connection QR is always visible in the
section's upper-right corner. It contains only the server address. The menu above
it can reveal an admin QR with a warning: scanning signs a phone in using your
admin account, granting control of your server. It returns to the guest QR when
the window loses focus, you leave Settings, or 60 seconds pass.
**Send an instant-login link to your phone** offers guest sharing first and admin
sharing behind the same warning. Only explicitly chosen admin codes and links
include the administrator API key. Hiding a code does not revoke a key already
scanned or shared. The toolbar copies only the primary connection address;
derived localhost URLs remain available for the native admin session.

**Apply & verify access** validates settings through ArchiveBox's config CLI,
restarts the container, checks the selected API addresses, and signs the native
browser in. Failed changes restore the configured values, including a blank
BASE_URL. Network changes preserve the collection and container's writable layer.

Optional Tailscale HTTPS runs Serve or, after choosing public access, Funnel.
Turning on **Allow access from users on the internet** opens a confirmation and
then automatically selects Tailscale HTTPS, applies Funnel, and verifies the
public address. Turning it off applies private access again. The verified public
URL is shown beside the checkbox; an automatic BASE_URL stays blank so private
connection addresses continue to work. Tailscale may require its own account
approval, in which case the app shows the approval link.
The app verifies the API and Tailscale access setting. Changing back to HTTP
removes the HTTPS listener it owns. Tailscale account approval may still require
a browser. Imported PEM certificates are supported. Cloudflare and Let's Encrypt
wildcard options currently provide setup guidance and existing-address checks;
automatic DNS authorization and certificate provisioning are not implemented.
Tailscale's built-in certificate does not provide wildcard snapshot subdomains.

Bonjour advertises enabled addresses on the local network. Mac discovery also
checks connected Tailscale peers. iOS cannot enumerate the Tailscale app's peers:
it uses nearby Bonjour, bounded LAN discovery, entered addresses, or a QR link
for servers elsewhere on the tailnet. mDNS itself does not cross the tailnet.

Shortcuts open the machine configuration, Personas, API Keys & Webhooks and logs.
CPU/RAM readings refresh every 10 seconds while the window is open; CPU needs two
samples. Activity and Users display active snapshot and superuser counts.

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

**Choose a path…** beside **Open in Finder** selects a different collection folder.
The default stays `~/Library/Application Support/ArchiveBox Server/data` until a
folder is chosen. The old collection stays where it is; switching does not move or
delete its files. The choice persists across launches and drives the container
mount, disk usage, Finder shortcut, and Shell path display.

Choosing a folder opens **Shell** and runs `archivebox init` in a temporary container
with that folder mounted at `/data`, showing real command output. Only after init
succeeds does the app start the server and reconnect the interactive shell. Existing
collections also run init; their configuration is preserved. New collections receive
the default local BASE_URL and need their own admin account. Browser sessions are
cleared when switching collections. Failed init stays visible in Shell; choose the
folder again to retry. A missing custom folder on later launches reports an error.

The collection survives application updates, quitting, and switching the client to
a remote server. No prototype data is migrated or reset. Port 5797 must be free.
Apple Container's service labels are global: another active installation must be
stopped before this one starts. The app does not take over someone else's runtime.

## App updates

Settings links to the bundled image on Docker Hub and displays its version, build
date, and bundled Linux kernel version. These values come from the actual packaged
OCI archive and kernel, so they do not change when the remote `dev` tag moves.

**Check for Updates** uses Sparkle 2.10.0. When a release is found, the button becomes
**Install Newer Version v…**, opening Sparkle's standard download/install dialog.
The update replaces the whole signed app, including its image, runtime and kernel.
There are no background update checks or independent image downloads. After relaunch,
a changed bundle build imports its payload and recreates only this app's container,
preserving the collection. Updating runtime helpers requires other containers to
be stopped first. The existing graceful quit path stops the server before replacement.

Local builds without a Sparkle public key show that updates require a release build.
Publishing needs a Developer ID identity, notarization, a Sparkle signing key and an
appcast; adding the framework alone does not publish an update service.

## Build

```sh
cd ServerApp
bash prepare.sh   # large downloads; build-machine step only
bash build.sh   # requires uv for reading the packaged image metadata
```

To rebuild and relaunch an existing developer installation, run
`bash install-local.sh`. It resolves the latest published `dev` image from both
registries, refreshes stale image payloads using this app's running runtime, and
records a new build number so startup recreates the container. It signs and verifies
a separate staged bundle, then atomically swaps it into `~/Applications` and keeps
the previous bundle for rollback. Do not overwrite or re-sign an installed executable
in place: a concurrent launch can otherwise crash with `CODESIGNING / Invalid Page`.

For an existing verified preparation directory, use
`ARCHIVEBOX_SERVER_ASSETS=/absolute/path/to/prepared/assets bash build.sh`.
Build output is `dist/ArchiveBox Server.app`. Local builds select an installed
Apple Development identity; set `ARCHIVEBOX_SIGNING_IDENTITY` to override it.
The app and Sparkle must share a real signing Team ID for hardened-runtime library
validation. Ad-hoc signing is rejected. This local build is **not a public downloadable release**.

Pinned components:

- Apple Container 1.4.1, Apple's signed installer, Apache-2.0.
- Guest init `ghcr.io/apple/containerization/vminit:0.45.0`.
- Kernel `vmlinux-6.18.35-197-debug`, recommended by that Container release,
  from Kata Containers 3.32.0. Linux is GPL-2.0; matching sources/configuration:
  <https://github.com/kata-containers/kata-containers/tree/3.32.0/tools/packaging/kernel>.
- ArchiveBox is resolved from the core release image recorded in
  `core-image.json`. Docker Hub and GHCR must agree, and both architectures
  must match the release tag and its published version.
  The resolved digest keys the release payload cache; the packaged ARM64 config
  digest is checked before signing. Builds stop if image publication is behind.
  The shipped version, source revision, and digest are recorded in `Info.plist`.
- SwiftTerm 1.19.0, MIT.

Apple's and SwiftTerm's licenses are copied into the bundle. ArchiveBox and its
Linux packages retain their upstream licenses. Apple's `system start` may try to
fetch its guest init before the bundled image import; fully offline first launch
has not been verified.

## Publish the optional download

Push significant app or packaging changes to `main`; the **Release apps** workflow
publishes both signed, notarized Mac apps together, updates the Sparkle feed, and
sends the same commit to TestFlight. See [release automation](../docs/RELEASES.md)
for versioning, credentials and retry instructions. The public companion asset is
`ArchiveBox.Server.app.zip`; it is downloaded only when explicitly requested.

The App Store client opens the release page for manual installation. The
`ArchiveBoxMacDirect` scheme uses the same client source with automatic download
support and the ReleaseDirect configuration. No new App Store listing is created.

## Live management acceptance check

With the installed companion running and no sign-in-capable admin yet, run from
this repository's root:

```sh
bash ServerApp/Tests/run.sh Management "$HOME/Applications/ArchiveBox Server.app"
```

This creates a randomly named temporary admin through the same management code,
checks password hashing/authentication, authenticated shortcut/progress responses,
validation failures and log exclusion, then removes that account and session.
It does not replace a visual check of onboarding, focus and the Activity webview.

`bash ServerApp/Tests/run.sh ClientBrowser "/path/to/ArchiveBox Server.app"`
checks the client's real WebKit pages with the existing administrator key,
including a first-connection session reset before opening Crawls, Snapshots and
Add URLs. It verifies authenticated rendered pages without printing credentials.

With the local profile selected in a signed development client,
`ARCHIVEBOX_SIGNING_IDENTITY=… bash ServerApp/Tests/run.sh ClientSettings "/path/to/ArchiveBox.app"`
checks saved localhost credentials and the companion handoff through the real
client settings model. It revalidates and saves that same connection in Keychain.

To verify HTTP settings against a running companion (temporarily changes its URL
and security mode, restarts twice, and restores the original effective settings):

```sh
bash ServerApp/Tests/run.sh HTTPSettings "$HOME/Applications/ArchiveBox Server.app"
```

Verify the installed agent with `bash ServerApp/Tests/run.sh OpenCode "/path/to/ArchiveBox Server.app"` from the repository root. The check uses the existing administrator session and verifies the embedded agent, health endpoint, and provider catalog without printing credentials.
