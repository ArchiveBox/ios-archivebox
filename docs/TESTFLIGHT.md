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
