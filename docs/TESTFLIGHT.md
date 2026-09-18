# TestFlight releases

Use the existing App Store Connect app `6769185501` (`io.archivebox.ArchiveBox`) for both platforms. Its temporary store name is **ArchiveBox Browser Extension**, pending Apple's release of **ArchiveBox**. Installed apps display **ArchiveBox**. Do not create another listing.

1. Sign in to the Apple developer account in Xcode → Settings → Apple Accounts. Browser sign-in alone does not refresh Xcode signing credentials.
2. Run `node scripts/prepare-safari.mjs`, then build a signed device archive:

   ```sh
   xcodebuild -project ArchiveBox.xcodeproj -scheme ArchiveBox \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath /tmp/ArchiveBox.xcarchive \
     DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates archive
   ```

3. Distribute through Xcode Organizer → App Store Connect, or export using an ExportOptions plist with `method=app-store-connect`, `destination=upload`, `signingStyle=automatic`, your `teamID`, and `manageAppVersionAndBuildNumber=true`.
4. Wait for processing, complete encryption information, then add the **iOS** build to the **ArchiveBox Internal** TestFlight group. This group intentionally uses manual build selection so old extension-only Mac builds are not distributed.

On this Mac, Xcode's export invokes Apple's rsync, whose subprocess can accidentally resolve Homebrew rsync and reject `--extended-attributes`. Export with `PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive ...` to keep both processes on the system implementation.

The generated Info.plists currently contain version `1.0` / build `1`; inspect the archive's actual version before uploading. Xcode can increment the distribution build number. A public App Store release remains a separate review/submission step.

## GitHub Actions publishing

The **TestFlight** workflow (`.github/workflows/testflight.yml`) supports manual
runs with an iOS/macOS/both selector and app version, plus `testflight-*` tags.
Ordinary pushes and pull requests continue to run the unsigned Build workflow.
Release jobs are serialized and use build number `100 + run_number.run_attempt`
so reruns cannot collide with a build still processing at Apple.

Configure these secrets in the repository's **testflight** environment:

- `ASC_KEY_ID`: the dedicated App Store Connect team API key ID.
- `ASC_ISSUER_ID`: the team's API issuer ID.
- `ASC_PRIVATE_KEY`: the complete downloaded `.p8` key, including its PEM headers.

The workflow uses Apple's cloud distribution signing; it does not store a
personal Apple ID password or distribution private key. The API key must have
the Admin role for cloud signing as well as TestFlight management. An App Manager
team key can upload builds but was rejected by cloud signing. This dedicated key
has team-wide access; the GitHub environment restricts releases to `main` and
`testflight-*` tags.
Keep it dedicated to this repository and revoke it in App Store Connect if lost.
The temporary key file is removed even when publishing fails.

After upload, `scripts/testflight-distribute.mjs` waits up to an hour for Apple,
checks for failed/invalid builds, records the platform-TLS-only encryption answer,
and assigns the matching version/build/platform to **ArchiveBox Internal**. It
verifies the group belongs to this app and confirms assignment before succeeding.
It does not submit a public App Store release or enable external testing.

If Apple processing exceeds the timeout, inspect App Store Connect before
rerunning: the binary may already have been accepted. The workflow summary lists
confirmed internal-group assignments. Never include the API key in build logs or
artifacts.

### Reusable development signing identity

The `testflight` GitHub environment needs `APPLE_DEVELOPMENT_P12` (base64 of an
encrypted PKCS#12 export of an existing Apple Development certificate and its
private key) and `APPLE_DEVELOPMENT_PASSWORD` (the export password). CI imports
that identity into a temporary keychain and removes it after the run. Reusing
one identity avoids exhausting Apple's development-certificate quota on
ephemeral runners; App Store distribution signing remains cloud-managed.
Only export a signing private key to GitHub with the certificate owner's approval.
