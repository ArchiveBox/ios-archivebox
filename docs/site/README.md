# Editing the app landing page

Product copy lives only in the repository's [README](../../README.md). The build
renders it with Jekyll and the GitHub Pages Primer theme, with a custom layout and
stylesheet here. Edit the README to change either the GitHub introduction or site.
Keep privacy and developer sections in closed `<details>` blocks.
Keep the visible copy focused on user benefits, screenshots, and a short getting
started guide. Do not add API mechanics, persistence rules, retry behavior, or
control-by-control instructions; detailed usage belongs in the apps and docs.

```sh
cd docs/site
bundle install
ALLOW_INCOMPLETE_SCREENSHOTS=1 bash build.sh --baseurl ''
bundle exec ruby -run -e httpd _site -p 4080
```

Use Ruby 3.3+ and Bundler. Dependencies are locked in `Gemfile.lock`.
`build.sh` stages only the README, theme files, and explicitly listed public images.
It never publishes application builds, signing files, or the server payload.
Add any new screenshot to its public image list. Use real app captures and inspect
them for credentials or private collection contents before committing.
Keep original full-resolution PNGs, at least twice their displayed width for
Retina screens. UI automation previews may be downsampled; don't use those as
published screenshots or upscale them to manufacture a higher resolution.

The iPhone images use real 1206 × 2622 simulator captures in
`docs/screenshots/raw/`. `docs/screenshots/frame.html?screen=home-iphone`
(and `connection-iphone`, `share-iphone`, `extension-iphone`) adds the same device
frame and transparent shadow to each. Serve that directory locally and export
at a 750 × 1500 viewport with a 2× pixel ratio to retain the original screen
pixels in a 1500 × 3000 PNG. Inspect the entire exported frame before publishing;
some capture tools apply an extra scale. The site must not add a border,
background, rounded clipping, or another shadow around these PNGs.

The **App website** workflow builds pull requests without deploying and deploys
commits to `main` through GitHub Actions to <https://app.archivebox.io/>.
Localized pages are independent files in `es/`, `fr/`, `zh/`, `ru/`, and `ar/`.
Delete those folders and the `language.js` include to remove localization.
The separate **Capture native app screenshots** workflow drives the shipping apps
with XCTest on disposable Macs: 14 screens each for iPhone and Mac, and 15 screens
for ArchiveBox Server.app. It reuses the real ArchiveBox bootstrap and the signed
companion build, including its container runtime. Onboarding is completed through
ordinary UI controls; there are no screenshot-specific app flags or injected states.
The exhaustive `testAllScreens` capture remains available with the collector's
`full` argument; the site's `gallery` tour focuses on onboarding, connections,
Add URLs, snapshots, AI Agent, activity, discovery and network guidance.

Each device job validates its own complete image set and publishes a separate
`site-screenshots-iphone`, `site-screenshots-macos`, or `site-screenshots-server`
artifact, retaining its app/backend revisions and PNG checksums. Pages restores
the newest validated set for each device independently, including successful jobs
from a run where another device failed. Capture completion triggers another Pages
build. Normal website pushes never wait for a capture job. Previously published
images remain available if capture artifacts expire.

`documentation-screenshots.json` supplies the existing photos only for device
groups that have never produced a validated capture. Preserve these images until
replacement captures are available; a port change alone is not a reason to delete
them. The same gallery data powers both product tabs and the two homepage marquees.
The main marquee contains only client screenshots; the smaller marquee between
the comparison table and Server.app button contains only companion screenshots.

To validate exported XCTest attachments for one device:

```sh
uv run --no-project python scripts/build-screenshot-gallery.py \
  --platform iphone --revision "$GITHUB_SHA" --backend-revision "$BACKEND_REVISION"
```

The capture script exports original XCTest PNGs plus attachment metadata. The
validator requires every named screen, a real PNG, and matching source provenance.
Its `--smoke` option permits an incomplete local preview only; Pages rejects it.
No generated CI captures are committed. iPad capture remains disabled.
