#!/usr/bin/env bash
set -euo pipefail
site_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$site_dir/../.." && pwd)"
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT

# Stage an explicit public asset list: building from the repository root would
# copy native builds, signing artifacts, and the multi-GB server payload to Pages.
cp "$site_dir/_config.yml" "$site_dir/index.html" "$stage_dir/"
cp -R "$site_dir/_layouts" "$site_dir/assets" "$stage_dir/"
mkdir -p "$stage_dir/_includes" "$stage_dir/docs/screenshots" "$stage_dir/App/AppIcon.icon/Assets" "$stage_dir/App/Assets.xcassets/ShareSheetGuide.imageset"
cp "$repo_dir/README.md" "$stage_dir/_includes/README.md"
cp "$repo_dir/docs/screenshots/"{library-mac,connection-mac}.png "$stage_dir/docs/screenshots/"
cp -R "$repo_dir/docs/icons" "$stage_dir/docs/"
cp "$repo_dir/App/AppIcon.icon/Assets/ArchiveBox.png" "$stage_dir/App/AppIcon.icon/Assets/"
cp "$repo_dir/App/Assets.xcassets/ShareSheetGuide.imageset/share-sheet.png" "$stage_dir/App/Assets.xcassets/ShareSheetGuide.imageset/"
cd "$site_dir"
BUNDLE_GEMFILE="$site_dir/Gemfile" bundle exec jekyll build --source "$stage_dir" --destination "$site_dir/_site" "$@"
