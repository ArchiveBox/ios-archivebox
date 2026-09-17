# ArchiveBox Server for macOS

The optional Apple-silicon/macOS 26+ companion to the main ArchiveBox app. It lives
in the same repository but builds independently and includes the full ArchiveBox
Linux image, Apple Container runtime, kernel, guest init, and SwiftTerm terminal.
The main iPhone/iPad/Mac client contains none of these large assets.

Open **ArchiveBox Server.app** to start your server. Its menu-bar archive icon opens
Archive or Settings & Terminal. There is no Dock icon. Closing the window keeps the
server running; Quit ArchiveBox Server stops its container. Quitting the main client
does not stop the companion.

- Server: `http://archivebox.localhost:18080`
- API: `http://api.archivebox.localhost:18080`
- Collection: `~/Library/Application Support/ArchiveBox Server/data`
- Runtime: `~/Library/Application Support/ArchiveBox Server/runtime`
- Logs: `~/Library/Application Support/ArchiveBox Server/desktop.log`

Create your own administrator account using the existing ArchiveBox UI or run
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
