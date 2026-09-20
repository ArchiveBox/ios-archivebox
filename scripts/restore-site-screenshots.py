#!/usr/bin/env python3
"""Restore validated capture output without running application CI."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
from urllib.error import HTTPError
from urllib.request import urlopen

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("kind", choices=["archivebox", "ios", "extension"])
parser.add_argument("destination", type=Path)
args = parser.parse_args()
args.destination.mkdir(parents=True, exist_ok=True)
# Native capture jobs publish independently: one failed device must not hide the
# other jobs' validated galleries or prevent normal Pages deployments.
if args.kind == 'ios':
    import shutil
    import tempfile

    groups = {}
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        repo = os.environ.get('GITHUB_REPOSITORY', 'ArchiveBox/ios-archivebox')
        if os.environ.get('GH_TOKEN'):
            runs = json.loads(subprocess.check_output([
                'gh', 'api', f'repos/{repo}/actions/workflows/screenshots.yml/runs?branch=main&per_page=100'
            ]))['workflow_runs']
            for run in runs:
                if run['event'] not in ('push', 'workflow_dispatch'):
                    continue
                artifacts = json.loads(subprocess.check_output([
                    'gh', 'api', f'repos/{repo}/actions/runs/{run["id"]}/artifacts'
                ]))['artifacts']
                for artifact in artifacts:
                    platform = artifact['name'].removeprefix('site-screenshots-')
                    if platform not in ('iphone', 'macos', 'server') or platform in groups or artifact['expired']:
                        continue
                    destination = root / platform
                    subprocess.run(['gh', 'run', 'download', str(run['id']), '--repo', repo,
                                    '--name', artifact['name'], '--dir', str(destination)], check=True)
                    manifest = json.loads((destination / 'manifest.json').read_text())
                    if manifest.get('complete') is not True or manifest['revision'] != run['head_sha']:
                        raise ValueError('Native capture artifact has invalid provenance')
                    if not manifest['captures'] or any(c['platform'] != platform for c in manifest['captures']):
                        raise ValueError('Native capture artifact has the wrong device group')
                    groups[platform] = (manifest, destination)
                if len(groups) == 3:
                    break
        # Retain published groups if their Actions artifacts have expired.
        base = 'https://app.archivebox.io/screenshots/'
        try:
            with urlopen(base + 'manifest.json', timeout=60) as response:
                published = json.load(response)
        except HTTPError as error:
            if error.code != 404:
                raise
            published = None
        if published:
            if published.get('complete') is not True:
                raise ValueError('Published native gallery must contain complete capture groups')
            for platform in ('iphone', 'macos', 'server'):
                captures = [c for c in published['captures'] if c['platform'] == platform]
                if platform in groups or not captures:
                    continue
                destination = root / platform
                for capture in captures:
                    relative = PurePosixPath(capture['path'])
                    if relative.is_absolute() or '..' in relative.parts or ':' in str(relative) or '\\' in str(relative):
                        raise ValueError('Unsafe screenshot path')
                    target = destination / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with urlopen(base + str(relative), timeout=60) as response:
                        target.write_bytes(response.read())
                groups[platform] = (dict(published, captures=captures), destination)
        captures = []
        for manifest, source in groups.values():
            for capture in manifest['captures']:
                relative = PurePosixPath(capture['path'])
                if relative.is_absolute() or '..' in relative.parts or ':' in str(relative) or '\\' in str(relative):
                    raise ValueError('Unsafe screenshot path')
                image = source / relative
                if capture.get('sha256') and hashlib.sha256(image.read_bytes()).hexdigest() != capture['sha256']:
                    raise ValueError(f'Screenshot checksum mismatch: {relative}')
                target = args.destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(image, target)
                captures.append(dict(capture, revision=capture.get('revision', manifest['revision']),
                                     backend_revision=capture.get('backend_revision', manifest['backend_revision'])))
        if captures:
            merged = dict(complete=True, revision=captures[0]['revision'], backend_revision=captures[0]['backend_revision'],
                          captures=captures, platforms=[{'id': p, 'label': p} for p in groups])
            (args.destination / 'manifest.json').write_text(json.dumps(merged, indent=2) + '\n')
            print(f'Restored {len(captures)} captures from {len(groups)} independently validated groups')
        else:
            print('No generated native captures available yet; retain documentation screenshots')
    raise SystemExit(0)

# Only successful default-branch capture runs are eligible, never PR artifacts.
if os.environ.get("GH_TOKEN"):
    repo = os.environ["GITHUB_REPOSITORY"]
    branch = "dev" if args.kind == "archivebox" else "main"
    runs = json.loads(
        subprocess.check_output(
            ["gh", "api", f"repos/{repo}/actions/workflows/screenshots.yml/runs?branch={branch}&status=success&per_page=100"]
        )
    )
    for run in runs["workflow_runs"]:
        if run["event"] not in ("push", "workflow_dispatch"):
            continue
        artifacts = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/actions/runs/{run['id']}/artifacts"]))
        if any(a["name"] == "site-screenshots" and not a["expired"] for a in artifacts["artifacts"]):
            subprocess.run(
                ["gh", "run", "download", str(run["id"]), "--repo", repo, "--name", "site-screenshots", "--dir", str(args.destination)],
                check=True,
            )
            print(f"Restored validated captures from run {run['id']} ({run['head_sha']})")
            raise SystemExit(0)
# Published captures remain available even after Actions artifacts expire.
base, manifest_name = {
    "archivebox": ("https://archivebox.io/screenshots/", "build.json"),
    "ios": ("https://app.archivebox.io/screenshots/", "manifest.json"),
    "extension": ("https://extension.archivebox.io/screenshots/", "manifest.json"),
}[args.kind]


def fetch(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or ":" in name or "\\" in name:
        raise ValueError(f"Unsafe capture path: {name}")
    with urlopen(base + name, timeout=60) as response:
        data = response.read()
    expected = hashes.get(name)
    if expected and hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"Capture checksum mismatch: {name}")
    target = args.destination / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)


try:
    with urlopen(base + manifest_name, timeout=60) as response:
        raw = response.read()
except HTTPError as error:
    if error.code == 404 and args.kind == "ios":
        print("No complete native gallery published yet; use the curated README screenshots.")
        raise SystemExit(0)
    raise
manifest = json.loads(raw)
hashes = {}
if args.kind == "archivebox":
    hashes = manifest["files"]
    names = [*hashes, "index.html"]
elif args.kind == "extension":
    names = [image["file"] for capture in manifest["screenshots"] for image in capture["images"]]
else:
    if manifest.get("complete") is not True:
        raise ValueError("Published native gallery must be complete")
    names = [capture["path"] for capture in manifest["captures"]]
with ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(fetch, names))
(args.destination / manifest_name).write_bytes(raw)
print(f"Restored {len(names)} published capture files, retaining revision {manifest['revision']}")
