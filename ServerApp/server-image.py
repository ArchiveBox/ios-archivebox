"""Resolve a published ArchiveBox image and verify the bundled ARM64 payload."""
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


def resolve(version=None, require_tip=True):
    ref = f"refs/tags/v{version}^{{}}" if version else "refs/heads/dev"
    revision_output = subprocess.check_output(
        ["git", "ls-remote", "https://github.com/ArchiveBox/ArchiveBox.git", ref], text=True
    ).split() if require_tip else []
    revision = revision_output[0] if revision_output else None
    if version and not revision:
        revision = subprocess.check_output(
            ["git", "ls-remote", "https://github.com/ArchiveBox/ArchiveBox.git", f"refs/tags/v{version}"], text=True
        ).split()[0]
    if version and not revision:
        raise SystemExit(f"ArchiveBox v{version} tag is missing")
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
        index, headers = get(base + "/manifests/" + (version or "dev"), token)
        digests.append(headers["Docker-Content-Digest"])
        for architecture in ("arm64", "amd64"):
            descriptor = next(item for item in index["manifests"] if item.get("platform", {}).get("architecture") == architecture)
            manifest, _ = get(base + "/manifests/" + descriptor["digest"], token)
            config, _ = get(base + "/blobs/" + manifest["config"]["digest"], token)
            labels = config["config"]["Labels"]
            actual = labels["org.opencontainers.image.revision"]
            if version and labels.get("org.opencontainers.image.version") != version:
                raise SystemExit(f"{host}:{version} ({architecture}) has the wrong ArchiveBox version")
            if revision is None:
                revision = actual
            if actual != revision:
                raise SystemExit(f"{host}:{version or 'dev'} ({architecture}) is at {actual}, but the source ref is {revision}. Wait for the ArchiveBox image release to finish before building the app.")
            if architecture == "arm64":
                arm_config = manifest["config"]["digest"]
    if len(set(digests)) != 1:
        raise SystemExit("Docker Hub and GHCR dev digests do not match; image publication is incomplete.")
    result = {"image": "archivebox/archivebox@" + digests[0], "digest": digests[0], "config": arm_config, "revision": revision}
    if version:
        result["version"] = version
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
            raise SystemExit("Bundled source revision does not match the resolved image.")
    print("Verified bundled ARM64 image:", expected["revision"])


os.chdir(Path(__file__).resolve().parent)
if sys.argv[1:] == ["resolve"]:
    resolve(version=os.environ.get("ARCHIVEBOX_VERSION"))
elif len(sys.argv) == 3 and sys.argv[1] == "resolve":
    resolve(version=sys.argv[2])
elif sys.argv[1:] == ["resolve", "--published"]:
    resolve(require_tip=False)
elif len(sys.argv) == 3 and sys.argv[1] == "verify":
    verify(sys.argv[2])
else:
    raise SystemExit("Usage: server-image.py resolve [--published] | verify /absolute/path/images.tar")
