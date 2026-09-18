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
cp "$repo_dir/docs/screenshots/"{library-mac,connection-mac,server-mac,server-shell,server-activity,server-clients,home-iphone,connection-iphone,share-iphone,extension-iphone}.png "$stage_dir/docs/screenshots/"
cp -R "$repo_dir/docs/icons" "$stage_dir/docs/"
cp "$repo_dir/App/AppIcon.icon/Assets/ArchiveBox.png" "$stage_dir/App/AppIcon.icon/Assets/"
cp "$repo_dir/App/Assets.xcassets/ShareSheetGuide.imageset/share-sheet.png" "$stage_dir/App/Assets.xcassets/ShareSheetGuide.imageset/"
gallery_dir="${SCREENSHOT_GALLERY_DIR:-$repo_dir/build/screenshots/gallery}"
if [[ ! -f "$gallery_dir/manifest.json" ]]; then
    if [[ "${ALLOW_INCOMPLETE_SCREENSHOTS:-0}" != 1 ]]; then
        echo "Build the native screenshot gallery first with scripts/build-screenshot-gallery.py" >&2
        exit 1
    fi
else
uv run --no-project python - "$gallery_dir/manifest.json" <<'CHECK'
import json, os, sys
manifest = json.load(open(sys.argv[1]))
if not manifest['complete'] and os.environ.get('ALLOW_INCOMPLETE_SCREENSHOTS') != '1':
    raise SystemExit('Incomplete screenshot galleries are local previews only')
if os.environ.get('GITHUB_SHA') and manifest['revision'] != os.environ['GITHUB_SHA']:
    raise SystemExit('Screenshot revision does not match this site build')
CHECK
mkdir -p "$stage_dir/_data" "$stage_dir/screenshots"
cp "$gallery_dir/manifest.json" "$stage_dir/_data/screenshots.json"
cp -R "$gallery_dir/." "$stage_dir/screenshots/"
cp "$site_dir/screenshots/index.html" "$stage_dir/screenshots/index.html"
fi
cd "$site_dir"
BUNDLE_GEMFILE="$site_dir/Gemfile" bundle exec jekyll build --source "$stage_dir" --destination "$site_dir/_site" "$@"
