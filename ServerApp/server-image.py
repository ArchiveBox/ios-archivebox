"""Resolve the published dev image and verify the actual bundled ARM64 payload."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import urllib.request


def get(url, token=None):
    headers = {"Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.load(response), response.headers


def resolve():
    revision = subprocess.check_output(
        ["git", "ls-remote", "https://github.com/ArchiveBox/ArchiveBox.git", "refs/heads/dev"], text=True
    ).split()[0]
    registries = [
        ("registry-1.docker.io", "https://auth.docker.io/token?service=registry.docker.io&scope=repository:archivebox/archivebox:pull"),
        ("ghcr.io", "https://ghcr.io/token?service=ghcr.io&scope=repository:archivebox/archivebox:pull"),
    ]
    digests = []
    arm_config = None
    for host, auth in registries:
        credentials, _ = get(auth)
        token = credentials.get("token") or credentials["access_token"]
        base = f"https://{host}/v2/archivebox/archivebox"
        index, headers = get(base + "/manifests/dev", token)
        digests.append(headers["Docker-Content-Digest"])
        for architecture in ("arm64", "amd64"):
            descriptor = next(item for item in index["manifests"] if item.get("platform", {}).get("architecture") == architecture)
            manifest, _ = get(base + "/manifests/" + descriptor["digest"], token)
            config, _ = get(base + "/blobs/" + manifest["config"]["digest"], token)
            actual = config["config"]["Labels"]["org.opencontainers.image.revision"]
            if actual != revision:
                raise SystemExit(f"{host}:dev ({architecture}) is at {actual}, but origin/dev is {revision}. Wait for the ArchiveBox image release to finish before building the app.")
            if architecture == "arm64":
                arm_config = manifest["config"]["digest"]
    if len(set(digests)) != 1:
        raise SystemExit("Docker Hub and GHCR dev digests do not match; image publication is incomplete.")
    result = {"image": "archivebox/archivebox@" + digests[0], "digest": digests[0], "config": arm_config, "revision": revision}
    Path("payload").mkdir(exist_ok=True)
    Path("payload/resolved-image.json").write_text(json.dumps(result, indent=2) + "\n")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for key, value in result.items():
                stream.write(f"{key}={value}\n")
    print(json.dumps(result))


def verify(path):
    expected = json.loads(Path("payload/resolved-image.json").read_text())
    with tarfile.open(path) as archive:
        def blob(digest):
            return json.load(archive.extractfile("blobs/" + digest.replace(":", "/")))
        index = json.load(archive.extractfile("index.json"))
        descriptor = next(item for item in index["manifests"] if item.get("annotations", {}).get("org.opencontainers.image.ref.name", "").endswith("archivebox/archivebox:dev"))
        manifest = blob(descriptor["digest"])
        if "manifests" in manifest:
            manifest = blob(next(item for item in manifest["manifests"] if item.get("platform", {}).get("architecture") == "arm64")["digest"])
        if manifest["config"]["digest"] != expected["config"]:
            raise SystemExit("Bundled image is stale: run ServerApp/prepare.sh to refresh it.")
        config = blob(manifest["config"]["digest"])
        if config["config"]["Labels"]["org.opencontainers.image.revision"] != expected["revision"]:
            raise SystemExit("Bundled source revision does not match origin/dev.")
    print("Verified bundled ARM64 image:", expected["revision"])


os.chdir(Path(__file__).resolve().parent)
if sys.argv[1:] == ["resolve"]:
    resolve()
elif len(sys.argv) == 3 and sys.argv[1] == "verify":
    verify(sys.argv[2])
else:
    raise SystemExit("Usage: server-image.py resolve | verify /absolute/path/images.tar")
