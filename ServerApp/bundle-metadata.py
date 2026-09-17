"""Read version/digests from the shipped OCI archive, not from a registry tag."""
import datetime
import json
import mmap
import os
from pathlib import Path
import plistlib
import re
import sys
import tarfile

app = Path(sys.argv[1])
with tarfile.open(app / 'Contents/Resources/images.tar') as archive:
    def blob(digest):
        return json.load(archive.extractfile('blobs/' + digest.replace(':', '/')))
    images = json.load(archive.extractfile('index.json'))['manifests']
    image = next(item for item in images if item['annotations']['org.opencontainers.image.ref.name'].endswith('archivebox/archivebox:dev'))
    manifest = blob(image['digest'])
    if 'manifests' in manifest:
        manifest = blob(next(item for item in manifest['manifests'] if item['platform']['architecture'] == 'arm64')['digest'])
    config = blob(manifest['config']['digest'])
with (app / 'Contents/Resources/vmlinux').open('rb') as kernel, mmap.mmap(kernel.fileno(), 0, access=mmap.ACCESS_READ) as data:
    kernel_version = re.search(rb'Linux version ([^\s]+)', data)[1].decode()
plist = app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
info.update(ArchiveBoxImageVersion=config['config']['Labels']['org.opencontainers.image.version'],
            ArchiveBoxImageCreated=datetime.datetime.fromisoformat(config['created'].replace('Z', '+00:00')).replace(tzinfo=None),
            ArchiveBoxImageDigest=image['digest'], ArchiveBoxKernelVersion=kernel_version,
            CFBundleVersion=os.environ.get('ARCHIVEBOX_BUILD_NUMBER', '1'),
            SUPublicEDKey=os.environ.get('ARCHIVEBOX_SPARKLE_PUBLIC_KEY', ''))
# App releases advance independently of the pinned ArchiveBox engine image.
info['CFBundleShortVersionString'] = os.environ.get('ARCHIVEBOX_APP_VERSION', info['ArchiveBoxImageVersion'])
plist.write_bytes(plistlib.dumps(info))
