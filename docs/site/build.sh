#!/usr/bin/env bash
set -euo pipefail
site_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$site_dir/../.." && pwd)"
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT

# Stage an explicit public asset list: building from the repository root would
# copy native builds, signing artifacts, and the multi-GB server payload to Pages.
cp "$site_dir/CNAME" "$site_dir/_config.yml" "$site_dir/index.html" "$stage_dir/"
cp -R "$site_dir/_layouts" "$site_dir/assets" "$stage_dir/"
mkdir -p "$stage_dir/_includes" "$stage_dir/docs/screenshots" "$stage_dir/App/AppIcon.icon/Assets" "$stage_dir/App/Assets.xcassets/ShareSheetGuide.imageset"
cp "$repo_dir/README.md" "$stage_dir/_includes/README.md"
cp "$site_dir/_includes/hero-gallery.html" "$stage_dir/_includes/"
cp "$repo_dir/docs/screenshots/"{library-mac,home-iphone,extension-iphone,connection-mac,archive-mac,archive-iphone,persona,connection-iphone,share-iphone,server-mac,server-shell,server-activity,server-clients,settings}.png "$stage_dir/docs/screenshots/"
cp -R "$repo_dir/docs/icons" "$stage_dir/docs/"
cp "$repo_dir/App/AppIcon.icon/Assets/ArchiveBox.png" "$stage_dir/App/AppIcon.icon/Assets/"
cp "$repo_dir/App/Assets.xcassets/ShareSheetGuide.imageset/share-sheet.png" "$stage_dir/App/Assets.xcassets/ShareSheetGuide.imageset/"
gallery_dir="${SCREENSHOT_GALLERY_DIR:-$repo_dir/build/screenshots/gallery}"
mkdir -p "$stage_dir/_data" "$stage_dir/screenshots"
cp "$site_dir/screenshots/index.html" "$stage_dir/screenshots/index.html"
uv run --no-project python - "$site_dir/documentation-screenshots.json" "$gallery_dir" "$stage_dir" <<'GALLERY'
import json, os, shutil, sys
from itertools import zip_longest
from pathlib import Path
catalog, generated, stage = map(Path, sys.argv[1:])
captures = json.loads(catalog.read_text())
manifest_path = generated / 'manifest.json'
if manifest_path.exists():
    manifest = json.loads(manifest_path.read_text())
    if not manifest['complete'] and os.environ.get('ALLOW_INCOMPLETE_SCREENSHOTS') != '1':
        raise SystemExit('Incomplete screenshot galleries are local previews only')
    if not manifest.get('revision') or not manifest.get('captures'):
        raise SystemExit('Missing capture provenance')
    current = []
    for capture in manifest['captures']:
        image = generated / capture['path']
        if not image.is_file():
            raise SystemExit(f'Missing screenshot: {image}')
        current.append(dict(capture, product='server' if capture['platform'] == 'server' else 'client', path='/screenshots/' + capture['path']))
    platforms = {c['platform'] for c in current}
    captures = [c for c in captures if c['platform'] not in platforms] + current
    shutil.copytree(generated, stage / 'screenshots', dirs_exist_ok=True)
# Alternate Mac and iPhone views in both the gallery and the hero strip.
priority = ['snapshots', 'library-mac', 'home-iphone', 'add', 'agent', 'activity', 'connection-connected']
def order(capture):
    return priority.index(capture['id']) if capture['id'] in priority else len(priority)
clients = [sorted([c for c in captures if c['platform'] == platform], key=order) for platform in ('macos', 'iphone')]
server = [c for c in captures if c['product'] == 'server']
captures = [c for pair in zip_longest(*clients) for c in pair if c is not None] + server
(stage / '_data/gallery.json').write_text(json.dumps(captures))
GALLERY
cd "$site_dir"
BUNDLE_GEMFILE="$site_dir/Gemfile" bundle exec jekyll build --source "$stage_dir" --destination "$site_dir/_site" "$@"
