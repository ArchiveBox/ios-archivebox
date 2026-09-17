#!/bin/bash
# Update an existing developer installation without modifying any mapped executable.
set -euo pipefail
cd "$(dirname "$0")"
app="${1:-$HOME/Applications/ArchiveBox Server.app}"
[[ -d "$app" ]] || { echo "Install the packaged companion first: $app" >&2; exit 1; }
lock="$app.install-lock"
mkdir "$lock" || { echo 'Another local installation is already running.' >&2; exit 1; }
trap 'rmdir "$lock"' EXIT
identity="${ARCHIVEBOX_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2; exit}')}"
[[ -n "$identity" && "$identity" != '-' ]] || { echo 'An Apple signing identity is required.' >&2; exit 1; }
swift build --build-system native --disable-build-manifest-caching -c release -Xlinker -rpath -Xlinker @executable_path/../Frameworks
staging=$(mktemp -d "$(dirname "$app")/.archivebox-update.XXXXXX")
staged="$staging/ArchiveBox Server.app"
# APFS clones reuse the large runtime/image payload without sharing writable inodes.
cp -cR "$app" "$staged"
cp .build/release/ArchiveBoxServer "$staged/Contents/MacOS/ArchiveBoxServer"
xcrun actool "$PWD/../App/Assets.xcassets" --compile "$staged/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 --output-format human-readable-text
codesign --force --options runtime --sign "$identity" "$staged"
codesign --verify --deep --strict "$staged"
uv run --no-project python - "$app" "$staged" <<'PY'
import ctypes
import os
import signal
import subprocess
import sys
import time

app, staged = sys.argv[1:]
executable = app + '/Contents/MacOS/ArchiveBoxServer'
def running():
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True).splitlines()
    return [int(pid) for row in rows if len(parts := row.strip().split(None, 1)) == 2
            for pid, path in [parts] if path == executable]
for pid in running():
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
for _ in range(100):
    if not running():
        break
    time.sleep(0.1)
else:
    raise SystemExit('App did not exit; leaving the installed bundle untouched.')
# A relaunch racing this operation can only map a complete old or new bundle.
# Never copy or re-sign files inside the installed bundle: that invalidates mapped pages.
libc = ctypes.CDLL(None, use_errno=True)
libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
libc.renamex_np.restype = ctypes.c_int
if libc.renamex_np(os.fsencode(staged), os.fsencode(app), 2):  # RENAME_SWAP
    raise OSError(ctypes.get_errno(), 'Atomic bundle swap failed')
print('Previous signed bundle retained at:', staged)
PY
codesign --verify --deep --strict "$app"
open "$app"
