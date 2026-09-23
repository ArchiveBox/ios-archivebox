# Automatic app releases

Push app changes to `main`. **Release apps** reserves a patch version and integer
build number in `release.json`, atomically pushing that commit plus a
`release-candidate/<source SHA>` tag. It follows the monorepo's candidate ownership
and exact-tested-artifact pattern, without adding this Swift app to the Python
package/PyPI dependency graph. A newer main push supersedes an unstarted candidate;
failed candidates can be rerun without allocating another version. Bot commits use
GitHub's built-in token, so they do not recursively trigger releases.

App sources, assets, project/package files, pinned runtime downloads, and packaging
scripts/workflows count as significant changes. Documentation or tests alone do
not. Changes are compared against the last published app release, so skipped
commits remain in the next changelog. To start a new release line, set the exact
version in `release.json` and remove its `source` field, retaining the build counter.
CI uses that baseline when it is newer than every existing release tag, then resumes
independent patch bumps. Run the workflow manually to retry.

The workflow tests shared Swift code, prepares the pinned WXT Safari extension,
downloads the pinned server payload (cached by preparation script hash), builds
both apps, signs with Developer ID, notarizes, staples and checks Gatekeeper.
It then creates a draft `vX.Y.Z` release, attaches both verified ZIPs, checks the
uploads, and publishes it. Public versioned assets are immutable. Release notes
include GitHub's generated PR notes plus every commit and git author
since the previous release, including direct pushes.

The only uploaded app-release downloads are **ArchiveBox.app.zip** and
**ArchiveBox Server.app.zip**. GitHub normalizes the server asset filename to
`ArchiveBox.Server.app.zip`; its display label retains the space. GitHub also adds
its own source-code archive links. Both apps require Apple Silicon and
macOS 26+. The optional server ZIP includes the runtime, Linux kernel and pinned
ArchiveBox container image. The client ZIP contains none of those large assets.
The stable `server-updates` prerelease holds only Sparkle's update feed.

In parallel, the existing TestFlight workflow builds the exact reserved
commit for iOS and macOS, assigns internal testing, and submits external beta
review. [Public TestFlight invitation](https://testflight.apple.com/join/wUG6DS6z).
Apple must approve external builds; successful upload is not public availability.
A TestFlight review failure does not unpublish the notarized Mac downloads.
The TestFlight script verifies both the archive and exported distribution package
before uploading. The direct-download script verifies the exported Mac client's
signing before notarization. See [signing policy and local releases](TESTFLIGHT.md).

The `testflight` GitHub environment holds `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_PRIVATE_KEY`, `DEVELOPER_ID_P12` (base64),
`DEVELOPER_ID_PROFILES` (base64 tar.gz of the three Developer ID provisioning profiles), `DEVELOPER_ID_PASSWORD`, and
`SPARKLE_PRIVATE_KEY` (base64 Ed25519 seed). Environment variables hold
`SPARKLE_PUBLIC_KEY`, `ASC_PUBLIC_GROUP_ID`, and `TESTFLIGHT_PUBLIC_URL`.
Release jobs are restricted to trusted main/tag refs. Private credentials are
written only under the runner's temporary directory and removed on exit; they
are never attached to releases or cached with the server payload.

The app version and engine image version are separate: the companion continues to
show the actual packaged engine version/digest. Once the core release has published
and verified its Docker images, the monorepo coordinator dispatches this workflow
with `archivebox_version`. The workflow resolves the immutable image tag in both
registries, checks its version and source revision against the core release tag,
and commits the resulting digest to `ServerApp/core-image.json`. That source commit
enters the normal app version reservation and signed release. Repeated dispatches
for the same image reuse the existing candidate or skip an already published release.
Core image updates rebuild the Mac downloads and Sparkle feed without resubmitting
the unchanged iOS/macOS client to TestFlight. Main pushes select TestFlight only
when client or shared source, assets, project configuration, or TestFlight packaging
changed; every Mac download still goes through the normal signing and notarization.

Developer ID export uses the imported identity and explicit profiles, not cloud
Developer ID signing. Renew the certificate and all three profiles together.
