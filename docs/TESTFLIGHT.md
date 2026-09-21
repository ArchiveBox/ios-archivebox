# TestFlight releases

Use the existing App Store Connect app **6769185501**, bundle ID
`io.archivebox.ArchiveBox`, for both iOS and macOS. Do not create another listing.

## One release path

CI, manually dispatched GitHub Actions, and local terminal releases use
`bash scripts/testflight.sh`. It archives, verifies development signatures,
exports **without uploading**, verifies the actual `.ipa` or `.pkg`, runs Apple's
upload validation, uploads that same package, and waits for Apple processing.
A successful export alone is not a successful release.

For a local release, install Xcode 27+, Node.js, pnpm and uv, sign into the team in
Xcode Settings, and ensure your Apple Development certificate has its private key
in the login keychain. Prepare the Safari resources, then run:

```sh
node scripts/prepare-safari.mjs
ASC_KEY_ID=YOUR_KEY_ID ASC_ISSUER_ID=YOUR_ISSUER_ID \
ASC_KEY_PATH=/absolute/path/to/AuthKey_YOUR_KEY_ID.p8 \
RELEASE_VERSION=1.0.115 RELEASE_BUILD=218.1 RELEASE_PLATFORM=both \
bash scripts/testflight.sh
```

Use an unused build number; the values above are examples, not a reservation.
`RELEASE_PLATFORM` accepts `iOS`, `macOS`, or `both`. Local releases reuse your
keychain; CI imports the encrypted development identity into a temporary keychain.
The script restores the previous keychain search list and deletes only its own
credential copies on exit. Archives and exports remain under `dist/testflight/`
(or `RELEASE_OUTPUT_DIR`) for inspection. Do not upload those directories wholesale
as public CI artifacts; distribution diagnostics may contain account information.

## Xcode Organizer and signing policy

The committed Xcode project and `project.yml` contain the same resource-sealing
phase in all eight app and extension targets. It runs for builds and archives, including
Organizer and direct-download builds, before the enclosing product is signed.
`ArchiveBoxCore_ArchiveBoxCore.bundle` contains only the Public Suffix List.
Its independent development signature is removed from each embedded copy;
its contents remain sealed by the app or extension's signature. Executables
and their entitlements are not stripped. The phase rejects a missing resource
or a resource bundle that declares an executable.

This follows Apple's [codeless bundle guidance](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle):
embedded codeless bundles in resource directories are signed as resources.
Do not repair a finished app with `codesign --deep --force`, disable signing
across the app, or change a package after validation.

For Organizer releases, archive **ArchiveBox** (iOS) or **ArchiveBoxMac** (Mac),
export for App Store Connect to disk, and check that exact export before upload:

```sh
uv run scripts/verify-signing.py --mode app-store /absolute/path/to/ArchiveBox.pkg
# Use the .ipa path for iOS.
```

The verifier checks the enclosing signatures, certificate membership in embedded
profiles, profile expiry, team and application IDs, distribution certificate type,
debugging entitlement, nested signers, and the resource-bundle policy. It does
not replace Apple's validation and processing checks. Organizer's direct Upload
button bypasses this repository's pre-upload verifier; use the release script for
the fully enforced sequence. An externally supplied stale archive cannot be fixed
by changing this project: rebuild it.

For inspecting a development archive, use `--mode development`; for the exported
Mac client distributed outside the store, use `--mode developer-id`.
`release-macos.sh` runs the latter automatically before notarization. Developer ID
and App Store signing are different distribution methods; do not interchange their
certificates or provisioning profiles.

## GitHub Actions credentials

The **TestFlight** workflow supports manual runs with platform/version inputs,
`testflight-*` tags, and reusable calls from **Release apps**. Release candidates
use the reserved `release.json` build plus the run attempt. Standalone Actions
runs use `100 + run_number`, plus the run attempt.

The repository's **testflight** environment requires:

- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`: the dedicated App Store Connect
  team API key, with Admin access for Apple's cloud distribution signing.
- `APPLE_DEVELOPMENT_P12`: base64 encrypted PKCS#12 containing the existing
  development certificate and private key.
- `APPLE_DEVELOPMENT_PASSWORD`: its export password.

Reusing the development identity avoids certificate-quota exhaustion on runners.
Distribution private keys remain cloud-managed. Restrict releases to trusted
refs, keep the API key dedicated to this repository, and rotate expired or revoked
credentials together with affected provisioning profiles. Never print or publish
private keys. Exporting someone else's private key requires their authorization.

## Acceptance

`testflight-distribute.mjs` requires Apple to report the exact platform, version
and build as `VALID`, then confirms internal-group assignment. With
`ASC_PUBLIC_GROUP_ID` configured, it also handles external beta-group assignment
and beta review submission. Apple review approval remains a separate gate.

If processing fails or times out, inspect the delivery in App Store Connect before
uploading again. A build can be rejected before it appears in the builds API;
a timeout does not mean it only needs more time. Check Apple's email/delivery
errors. Never treat an unrelated green GitHub release or iOS acceptance as proof
that the macOS build passed.
