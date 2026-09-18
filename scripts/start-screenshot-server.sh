#!/bin/bash
# Bootstrap a real, disposable ArchiveBox collection on a hosted screenshot runner.
set -euo pipefail
umask 077
backend=${1:?Usage: start-screenshot-server.sh BACKEND_CHECKOUT FRESH_DATA_DIRECTORY}
data=${2:?Usage: start-screenshot-server.sh BACKEND_CHECKOUT FRESH_DATA_DIRECTORY}
backend=$(cd "$backend" && pwd)
mkdir -p "$data"
data=$(cd "$data" && pwd)
if [[ -n "$(ls -A "$data")" ]]; then
    echo "Screenshot data directory must be empty: $data" >&2
    exit 1
fi
port=${SCREENSHOT_SERVER_PORT:-8000}
export BASE_URL="http://127.0.0.1:$port" BIND_ADDR="127.0.0.1:$port"
export ARCHIVEBOX_TEST_SERVER="$BASE_URL"
export SCREENSHOT_USERNAME=archivebox-screenshots
export SCREENSHOT_PASSWORD
SCREENSHOT_PASSWORD=$(openssl rand -hex 24)
export SCREENSHOT_API_KEY_FILE="$data/api-key"
# Fail before populating the archive if another service owns this port.
uv run --no-sync --project "$backend" python - "$port" <<'PY'
import socket
import sys
with socket.socket() as sock:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
PY
cd "$data"
abx() { uv run --no-sync --project "$backend" archivebox "$@"; }
abx init --quick
abx manage shell --no-imports -c '
import os
from pathlib import Path
from django.contrib.auth import get_user_model
from archivebox.api.models import APIToken
user = get_user_model().objects.create_superuser(username=os.environ["SCREENSHOT_USERNAME"], password=os.environ["SCREENSHOT_PASSWORD"])
Path(os.environ["SCREENSHOT_API_KEY_FILE"]).write_text(APIToken.objects.create(created_by=user).token)
'
abx persona create 'Research Browser'
# Match the main app screenshot collector: configure its real AI interface before startup.
opencode_port=$(uv run --no-sync --project "$backend" python - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PYPORT
)
# Use the built-in SQLite search backend; Sonic has no supported Intel macOS binary.
abx config --set SEARCH_BACKEND_ENGINE=sqlite SEARCH_BACKEND_SONIC_ENABLED=False SEARCH_BACKEND_SQLITE_ENABLED=True \
    PLUGINS=title,headers,wget,screenshot,search_backend_sqlite,opencode OPENCODE_ENABLED=True "OPENCODE_PORT=$opencode_port"
abx manage shell --no-imports -c '
from archivebox.config.common import get_config
config = get_config()
assert config.OPENCODE_ENABLED is True, "The AI Agent must be enabled for capture"
assert config.SEARCH_BACKEND_ENGINE == "sqlite", "Crawls must use SQLite search"
assert config.SEARCH_BACKEND_SQLITE_ENABLED is True, "SQLite search must be enabled"
assert config.SEARCH_BACKEND_SONIC_ENABLED is False, "This collection uses SQLite search"
'
abx install opencode --binproviders=env,pnpm
# Install only the dependencies used by this gallery, through the real installer.
abx install chrome wget title headers screenshot
abx add --depth=0 --tag=documentation,reference \
    --plugins=title,headers,wget,screenshot,search_backend_sqlite https://example.com https://archivebox.io
abx manage shell --no-imports -c '
from pathlib import Path
from archivebox.core.models import Snapshot, ArchiveResult
snapshots = list(Snapshot.objects.filter(status=Snapshot.StatusChoices.SEALED))
assert len(snapshots) == 2, f"Expected two complete snapshots, got {len(snapshots)}"
for snapshot in snapshots:
    for plugin in ("title", "wget", "screenshot"):
        assert ArchiveResult.objects.filter(snapshot=snapshot, plugin=plugin, status="succeeded").exists(), f"Missing {plugin} result for {snapshot.url}"
    image = Path(snapshot.output_dir) / "screenshot" / "screenshot.png"
    assert image.is_file() and image.stat().st_size > 0, f"Missing screenshot image: {image}"
'
server_pid=''
ready=0
complete=0
cleanup_failure() {
    if [[ "$complete" != 1 && -n "$server_pid" ]]; then
        for child in $(pgrep -P "$server_pid" || true); do kill "$child" 2>/dev/null || true; done
        kill "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup_failure EXIT
# Keep the runner's tracking ID: GitHub cleans up the process tree at job end.
# nohup keeps this server available to subsequent steps after this shell exits.
nohup uv run --no-sync --project "$backend" archivebox server "$BIND_ADDR" \
    > "$data/server.log" 2>&1 < /dev/null &
server_pid=$!
printf '%s\n' "$server_pid" > "$data/server.pid"
for attempt in $(seq 1 60); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo 'ArchiveBox exited before readiness.' >&2
        tail -100 "$data/server.log" >&2
        exit 1
    fi
    if curl --fail --silent --max-time 2 "$BASE_URL/admin/login/" > /dev/null; then
        ready=1
        break
    fi
    sleep 1
done
if [[ "$ready" != 1 ]]; then
    echo 'ArchiveBox did not become ready within 60 checks.' >&2
    tail -100 "$data/server.log" >&2
    exit 1
fi
export ARCHIVEBOX_TEST_TOKEN
ARCHIVEBOX_TEST_TOKEN=$(cat "$SCREENSHOT_API_KEY_FILE")
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    printf '::add-mask::%s\n' "$ARCHIVEBOX_TEST_TOKEN"
fi
# Discovery uses the OpenAPI schema, so validate that endpoint before starting the app.
curl --fail --silent --show-error --max-time 15 \
    "$BASE_URL/api/v1/openapi.json" > "$data/openapi.json"
uv run --no-sync --project "$backend" python - "$data/openapi.json" <<'PY'
import json
import sys
schema = json.load(open(sys.argv[1]))
assert "archivebox" in schema["info"]["title"].lower()
for endpoint in ("/cli/add", "/auth/check_api_token"):
    assert any(path.endswith(endpoint) for path in schema["paths"]), endpoint
PY
# Validate the same authenticated API the native app consumes without logging the key.
curl --fail --silent --show-error --max-time 15 \
    -H "X-ArchiveBox-API-Key: $ARCHIVEBOX_TEST_TOKEN" \
    "$BASE_URL/api/v1/core/snapshots" > "$data/snapshots.json"
uv run --no-sync --project "$backend" python - "$data/snapshots.json" <<'PY'
import json
import sys
response = json.load(open(sys.argv[1]))
assert response["count"] == 2, response["count"]
snapshots = response["items"]
assert len(snapshots) == 2, f"Expected two API snapshots, got {len(snapshots)}"
assert all(snapshot["title"] for snapshot in snapshots), "Missing API snapshot titles"
PY
for variable in ARCHIVEBOX_TEST_SERVER ARCHIVEBOX_TEST_TOKEN; do
    printf '%s=%s\n' "$variable" "${!variable}" >> "$data/connection.env"
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf '%s=%s\n' "$variable" "${!variable}" >> "$GITHUB_ENV"
    fi
done
complete=1
echo "ArchiveBox screenshot server ready at $BASE_URL with two archived pages."
