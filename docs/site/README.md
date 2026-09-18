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
bash build.sh --baseurl ''
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

The **App website** workflow builds pull requests without deploying. On `main`, it
deploys through GitHub Actions to <https://archivebox.github.io/ios-archivebox/>.
The repository's Pages source must be **GitHub Actions**. App distribution and
TestFlight continue to use their own release workflows.
