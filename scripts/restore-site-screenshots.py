#!/usr/bin/env -S uv run --no-project python
"""Restore validated capture output without running application CI."""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".github/pages"))
import artifacts

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
args.destination.mkdir(parents=True, exist_ok=True)
# Native capture jobs publish independently: one failed device must not hide the
# other jobs' validated galleries or prevent normal Pages deployments.
import shutil
import tempfile

ARTIFACT_NAMES = ("site-screenshots-iphone", "site-screenshots-macos", "site-screenshots-server")

groups = {}
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo = "ArchiveBox/ios-archivebox"
    if os.environ.get("GH_TOKEN"):
        for run in artifacts.runs(repo, "screenshots.yml", "main", successful=False, artifact_names=ARTIFACT_NAMES):
            for name in sorted(artifacts.names(repo, run)):
                platform = name.removeprefix("site-screenshots-")
                if platform not in ("iphone", "macos", "server") or platform in groups:
                    continue
                destination = root / platform
                artifacts.download(repo, run, name, destination)
                manifest = json.loads((destination / "manifest.json").read_text())
                if (
                    manifest.get("complete") is not True
                    or manifest["revision"] != run["head_sha"]
                ):
                    raise ValueError("Native capture artifact has invalid provenance")
                if not manifest["captures"] or any(
                    c["platform"] != platform for c in manifest["captures"]
                ):
                    raise ValueError(
                        "Native capture artifact has the wrong device group"
                    )
                groups[platform] = (manifest, destination)
            if len(groups) == 3:
                break
    # Retain published groups if their Actions artifacts have expired.
    base = "https://app.archivebox.io/screenshots/"
    try:
        published = (
            json.loads(artifacts.fetch(base, "manifest.json"))
            if len(groups) < 3
            else None
        )
    except HTTPError as error:
        if error.code != 404:
            raise
        published = None
    if published:
        if published.get("complete") is not True:
            raise ValueError(
                "Published native gallery must contain complete capture groups"
            )
        for platform in ("iphone", "macos", "server"):
            captures = [c for c in published["captures"] if c["platform"] == platform]
            if platform in groups or not captures:
                continue
            destination = root / platform
            for capture in captures:
                relative = artifacts.relative_path(capture["path"])
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(artifacts.fetch(base, str(relative)))
            groups[platform] = (dict(published, captures=captures), destination)
    captures = []
    for manifest, source in groups.values():
        for capture in manifest["captures"]:
            relative = artifacts.relative_path(capture["path"])
            image = source / relative
            if (
                capture.get("sha256")
                and hashlib.sha256(image.read_bytes()).hexdigest() != capture["sha256"]
            ):
                raise ValueError(f"Screenshot checksum mismatch: {relative}")
            target = args.destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(image, target)
            captures.append(
                dict(
                    capture,
                    revision=capture.get("revision", manifest["revision"]),
                    backend_revision=capture.get(
                        "backend_revision", manifest["backend_revision"]
                    ),
                )
            )
    if captures:
        merged = dict(
            complete=True,
            revision=captures[0]["revision"],
            backend_revision=captures[0]["backend_revision"],
            captures=captures,
            platforms=[{"id": p, "label": p} for p in groups],
        )
        (args.destination / "manifest.json").write_text(
            json.dumps(merged, indent=2) + "\n"
        )
        print(
            f"Restored {len(captures)} captures from {len(groups)} independently validated groups"
        )
    else:
        print(
            "No generated native captures available yet; retain documentation screenshots"
        )
raise SystemExit(0)
