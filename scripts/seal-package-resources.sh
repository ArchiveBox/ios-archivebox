#!/bin/bash
set -euo pipefail
# WHY: Xcode 27 archives SwiftPM's data bundle with Apple Development, but an
# App Store export can leave that signature intact while re-signing the enclosing
# app with Apple Distribution. This caused ITMS-90284 in all four Mac products.
# A team-ID check or codesign --verify alone misses this: both certificates can
# belong to the same team, and each signature can be individually valid.
#
# Run after SwiftPM copies resources, BEFORE Xcode signs the enclosing product.
# Codeless bundles at the resource location (Contents/Resources on Mac, the flat
# product directory on iOS) are sealed by that product's signature:
# https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
# Removing this data-only signature does not leave the data unprotected: changing
# its bytes after product signing invalidates the enclosing signature.
#
# Only modify the target's copied bundle: SwiftPM's shared product may still be
# used by concurrent builds. If this bundle gains code, its signing needs review;
# never extend signature removal to executable bundles.
#
# project.yml is the source of the eight target phases; XcodeGen embeds this file
# into project.pbxproj. Regenerate the committed project after changing this file
# so Xcode Organizer, xcodebuild and CI all execute the same policy.
bundle="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/ArchiveBoxCore_ArchiveBoxCore.bundle"
contents="$bundle"
resources="$bundle"
if [[ -d "$bundle/Contents" ]]; then
    contents="$bundle/Contents"
    resources="$contents/Resources"
fi
plist="$contents/Info.plist"
[[ -f "$plist" && -f "$resources/public_suffix_list.dat" ]] || {
    echo "error: Missing ArchiveBoxCore resource bundle: $bundle" >&2; exit 1;
}
if /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" >/dev/null 2>&1; then
    echo "error: ArchiveBoxCore resources now contain an executable; review their signing policy" >&2
    exit 1
fi
# Only the known data bundle is touched, never an executable or its entitlements.
if [[ -d "$contents/_CodeSignature" ]]; then
    /usr/bin/codesign --remove-signature "$bundle"
    # codesign leaves the now-empty signature directory behind.
    rmdir "$contents/_CodeSignature"
fi
[[ ! -d "$contents/_CodeSignature" ]] || {
    echo "error: Resource bundle still carries an independent signature" >&2; exit 1;
}
