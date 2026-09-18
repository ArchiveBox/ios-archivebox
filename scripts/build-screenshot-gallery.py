#!/usr/bin/env python3
"""Validate real XCTest exports and stage the native screenshot gallery."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
import struct

COMMON = "connection-disconnected connection-connected sidebar add add-guide persona-picker safari-setup agent-welcome agent activity crawls schedules snapshots results tags admin users personas keys webhooks processes machines interfaces binaries plugins workers logs".split()
EXPECTED = {p: COMMON + (['connection-local', 'about'] if p == 'macos' else ['share-accepted', 'share-tags', 'share-removal-confirmation', 'share-removed']) for p in ['iphone', 'ipad', 'macos']}
LABELS = {'iphone': 'iPhone', 'ipad': 'iPad', 'macos': 'Mac'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, default=Path('build/screenshots'))
    parser.add_argument('--output', type=Path, default=Path('build/screenshots/gallery'))
    parser.add_argument('--revision', required=True)
    parser.add_argument('--backend-revision', required=True)
    parser.add_argument('--smoke', action='store_true', help='Local preview only: accept incomplete real captures; never publish this output.')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.revision):
        parser.error('--revision must be a full Git commit SHA')
    if not args.smoke and not re.fullmatch(r'[0-9a-f]{40}', args.backend_revision):
        parser.error('--backend-revision must be a full Git commit SHA')
    captures = []
    for platform, expected in EXPECTED.items():
        source = args.input / platform
        if args.smoke and not source.exists():
            continue
        metadata = json.loads((source / 'metadata.json').read_text())
        for key, value in [('revision', args.revision), ('backend_revision', args.backend_revision), ('platform', platform)]:
            if metadata.get(key) != value:
                raise ValueError(f'{platform}: metadata {key} does not match requested build')
        records = json.loads((source / 'attachments/manifest.json').read_text())
        found = {}
        for record in records:
            for attachment in record.get('attachments', []):
                name = attachment.get('suggestedHumanReadableName', '')
                matches = [screen for screen in expected if re.fullmatch(re.escape(screen) + r'(?:_\d+_[0-9A-Fa-f-]+)?(?:\.png)?', name)]
                if not matches and args.smoke:
                    smoke_name = re.fullmatch(r'([a-z][a-z0-9-]+)(?:_\d+_[0-9A-Fa-f-]+)?\.png', name)
                    if smoke_name:
                        matches = [smoke_name[1]]
                if not matches:
                    continue
                screen = matches[0]
                if screen in found or attachment.get('isAssociatedWithFailure'):
                    raise ValueError(f'{platform}: duplicate or failed capture {screen}')
                filename = attachment['exportedFileName']
                if Path(filename).name != filename:
                    raise ValueError('Attachment paths must be filenames')
                image = source / 'attachments' / filename
                with image.open('rb') as stream:
                    header = stream.read(24)
                if header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR':
                    raise ValueError(f'{image}: expected an original PNG attachment')
                width, height = struct.unpack('>II', header[16:24])
                if min(width, height) <= 0:
                    raise ValueError(f'{image}: invalid dimensions')
                timestamp = datetime.fromtimestamp(float(attachment['timestamp']), timezone.utc).isoformat()
                found[screen] = dict(id=screen, platform=platform, platform_label=LABELS[platform], title=screen.replace('-', ' ').title(), width=width, height=height, captured_at=timestamp, device=attachment['deviceName'], path=f'images/{platform}/{screen}.png', source=image)
        missing = set(expected) - found.keys()
        if missing and not args.smoke:
            raise ValueError(f'{platform}: missing screenshots: {", ".join(sorted(missing))}')
        captures.extend(found[screen] for screen in (list(found) if args.smoke else expected) if screen in found)
    if not captures:
        raise ValueError('No named native screenshots found')
    # Validate every input before replacing previously generated output.
    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.mkdir(parents=True)
    for capture in captures:
        destination = args.output / capture['path']
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(capture.pop('source'), destination)
    manifest = dict(revision=args.revision, backend_revision=args.backend_revision, complete=not args.smoke, platforms=[dict(id=p, label=LABELS[p]) for p in EXPECTED if any(c['platform'] == p for c in captures)], captures=captures)
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Validated {len(captures)} native screenshots into {args.output}')


if __name__ == '__main__':
    main()
