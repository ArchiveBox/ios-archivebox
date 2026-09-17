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
commits remain in the next changelog. Bump the major/minor version in `release.json`
when needed; CI allocates the next patch. Run the workflow manually to retry.

The workflow tests shared Swift code, prepares the pinned WXT Safari extension,
downloads the pinned server payload (cached by preparation script hash), builds
both apps, signs with Developer ID, notarizes, staples and checks Gatekeeper.
It then creates a draft `vX.Y.Z` release, attaches both verified ZIPs, checks the
uploads, and publishes it. Public versioned assets are immutable. Release notes
include GitHub's generated PR/contributor notes plus every commit and git author
since the previous release, including direct pushes.

Downloads are **ArchiveBox.app.zip** and **ArchiveBox.Server.app.zip**, with
`SHA256SUMS` and the signed server `appcast.xml`. Both require Apple Silicon and
macOS 26+. The optional server ZIP includes the runtime, Linux kernel and pinned
ArchiveBox container image. The client ZIP contains none of those large assets.
The stable `server-updates` prerelease holds only Sparkle's update feed.

After publication, the existing TestFlight workflow builds the exact reserved
commit for iOS and macOS, assigns internal testing, and submits external beta
review. [Public TestFlight invitation](https://testflight.apple.com/join/wUG6DS6z).
Apple must approve external builds; successful upload is not public availability.
A TestFlight review failure does not unpublish the notarized Mac downloads.

The `testflight` GitHub environment holds `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_PRIVATE_KEY`, `DEVELOPER_ID_P12` (base64),
`DEVELOPER_ID_PROFILES` (base64 tar.gz of the three Developer ID provisioning profiles), `DEVELOPER_ID_PASSWORD`, and
`SPARKLE_PRIVATE_KEY` (base64 Ed25519 seed). Environment variables hold
`SPARKLE_PUBLIC_KEY`, `ASC_PUBLIC_GROUP_ID`, and `TESTFLIGHT_PUBLIC_URL`.
Release jobs are restricted to trusted main/tag refs. Private credentials are
written only under the runner's temporary directory and removed on exit; they
are never attached to releases or cached with the server payload.

The app version and engine image version are separate: the companion continues to
show the actual packaged engine version/digest. Updating the engine is a pinned
`ServerApp/prepare.sh` change, not an unverified pull of a mutable image tag.

Developer ID export uses the imported identity and explicit profiles, not cloud
Developer ID signing. Renew the certificate and all three profiles together.
