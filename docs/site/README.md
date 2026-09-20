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
(and `extension-iphone`) adds the same device
frame and transparent shadow to each. Serve that directory locally and export
at a 750 × 1500 viewport with a 2× pixel ratio to retain the original screen
pixels in a 1500 × 3000 PNG. Inspect the entire exported frame before publishing;
some capture tools apply an extra scale. The site must not add a border,
background, rounded clipping, or another shadow around these PNGs.

The **App website** workflow builds pull requests without deploying and deploys
commits to `main` through GitHub Actions to <https://app.archivebox.io/>.
The separate **Capture native app screenshots** workflow captures iPhone and Mac
on app changes to `main`. Successful captures trigger a new website deployment;
other website builds retain the latest complete gallery. iPad capture is disabled
for now.
The repository's Pages source must be **GitHub Actions**. App distribution and
TestFlight continue to use their own release workflows.

The Screenshots page is generated from real XCTest attachments for iPhone and
Mac. CI captures the current app revision against a pinned ArchiveBox server,
then runs:

```sh
uv run --no-project python scripts/build-screenshot-gallery.py \
  --revision "$GITHUB_SHA" --backend-revision "$BACKEND_REVISION"
```

Run that command from the repository root. Each
`build/screenshots/{iphone,macos}/metadata.json` must contain matching
`revision`, `backend_revision`, and `platform` values alongside the exported
`attachments/manifest.json`. The converter validates all required named screens,
PNG dimensions, timestamps, and provenance before staging original images under
`build/screenshots/gallery/`. No generated captures are committed.

Before the first complete capture, `build.sh` publishes the documentation images.
Once a generated gallery is available, it must contain all 31 iPhone and 33 Mac
screenshots.
To inspect a genuine partial capture export, the converter's explicit `--smoke`
flag permits missing screens/platforms and `--backend-revision none` when no server
was used. Build that output with `ALLOW_INCOMPLETE_SCREENSHOTS=1` and optionally
`SCREENSHOT_GALLERY_DIR=/path/to/gallery`; it is visibly marked incomplete and
must never be deployed. Full-resolution PNGs retain the original capture pixels.
The share extension is captured through Safari on every platform. The optional
Server.app and external browser/settings destinations are outside this app gallery.
