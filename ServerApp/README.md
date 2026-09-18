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

Settings shows the server's actual BASE_URL, admin and API URLs with copy buttons,
plus its Tailscale DNS name (or IP) when connected. The Tailscale row is detection
only: the server remains bound to localhost, so remote access needs a proxy.
Shortcuts open the current machine's config editor, Personas, API Keys & Webhooks,
and Debug Logs inside Archive. The machine config editor syncs with ArchiveBox.conf.

The upper-right toolbar shows server status, a BASE_URL glass button (click once
to copy), and plain CPU/RAM readings. Activity and Users show active snapshot and
superuser counts. Resource readings refresh every 10 seconds while the window is
open; CPU needs two samples. **HTTP, TLS, and DNS** provides BASE_URL and
SERVER_SECURITY_MODE fields. **Apply & Restart** validates and saves both using
ArchiveBox's config CLI, then stops/starts the existing container. Its writable
layer and mounted collection are preserved; bundle updates still recreate it.
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
a remote server. No prototype data is migrated or reset. Port 18080 must be free.
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
- ArchiveBox is resolved from the latest published `dev` image at build time.
  Docker Hub and GHCR must agree, and both architectures must match `origin/dev`.
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

To verify HTTP settings against a running companion (temporarily changes its URL
and security mode, restarts twice, and restores the original effective settings):

```sh
bash ServerApp/Tests/run.sh HTTPSettings "$HOME/Applications/ArchiveBox Server.app"
```

Verify the installed agent with `bash ServerApp/Tests/run.sh OpenCode "/path/to/ArchiveBox Server.app"` from the repository root. The check uses the existing administrator session and verifies the embedded agent, health endpoint, and provider catalog without printing credentials.
