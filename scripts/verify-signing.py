#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Verify a real app/archive/export before upload; never modify its signatures.

`codesign --verify` checks integrity, not whether a provisioning profile permits
the signer. ITMS-90284 occurred with individually valid signatures from different
certificates on the same team. Check leaf certificates against embedded profiles.

Modes describe signing, not Debug/Release compiler settings: development checks
the intermediate archive; app-store checks exports for TestFlight AND the public
store; developer-id checks the separately distributed Mac client. The latter
still needs notarization/Gatekeeper in release-macos.sh. Apple's validation and
processing remain required; review these checks when adding new signed products.
"""
import argparse
import datetime
import pathlib
import plistlib
import subprocess
import tempfile


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def require(condition, message):
    if not condition:
        raise ValueError(message)


def signing_certificate(path, temporary):
    prefix = str(temporary / "certificate")
    leaf = pathlib.Path(prefix + "0")
    leaf.unlink(missing_ok=True)
    run("codesign", "-d", f"--extract-certificates={prefix}", str(path))
    require(leaf.is_file(), f"Missing signing certificate (possibly ad-hoc): {path}")
    return leaf.read_bytes()


def verify(app, mode, team, temporary):
    run("codesign", "--verify", "--deep", "--strict", str(app))
    certificates = {}
    products = [app, *sorted(app.rglob("*.appex"))]
    for product in products:
        mac = (product / "Contents/Info.plist").is_file()
        contents = product / "Contents" if mac else product
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        profile_path = contents / ("embedded.provisionprofile" if mac else "embedded.mobileprovision")
        profile = None
        if profile_path.is_file():
            profile = plistlib.loads(run("security", "cms", "-D", "-i", str(profile_path)))
            require(profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
                    f"Expired profile: {product}")
            require(team in profile["TeamIdentifier"], f"Wrong profile team: {product}")
        details = subprocess.run(["codesign", "-dvv", str(product)], capture_output=True, check=True).stderr.decode()
        require(f"TeamIdentifier={team}" in details, f"Wrong signature team: {product}")
        certificate = signing_certificate(product, temporary)
        certificates[product] = certificate
        entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(product)))
        if profile is not None:
            # Profiles authorize particular signing certificates and app IDs.
            # Sharing a team does not authorize an arbitrary certificate, and
            # certificate renewal can require a newly generated profile.
            require(certificate in profile["DeveloperCertificates"], f"Signing certificate absent from profile: {product}")
            app_id_key = "com.apple.application-identifier" if mac else "application-identifier"
            expected_id = f"{profile['ApplicationIdentifierPrefix'][0]}.{info['CFBundleIdentifier']}"
            require(entitlements.get(app_id_key) == expected_id, f"Incorrect signed application identifier: {product}")
            allowed_id = profile["Entitlements"].get(app_id_key, "")
            require(allowed_id == expected_id or (allowed_id.endswith(".*") and expected_id.startswith(allowed_id[:-1])),
                    f"Profile does not permit application identifier: {product}")
        else:
            # Xcode omits profiles for the Mac widget: it
            # requests only App Sandbox, which does not require provisioning.
            require(mac and product != app
                    and set(entitlements) <= {"com.apple.security.app-sandbox"},
                    f"Missing provisioning profile: {product}")
            require(certificate == certificates[app], f"Unprovisioned extension signer differs from app: {product}")
        if mode != "development":
            # Distribution must not carry debugger access or device-limited
            # development profiles, even when the audience is TestFlight testers.
            require(not entitlements.get("get-task-allow") and not entitlements.get("com.apple.security.get-task-allow"),
                    f"Distribution product permits debugging: {product}")
            if mode == "app-store":
                require(profile is None or ("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices")),
                        f"Not an App Store provisioning profile: {product}")
                require("Authority=Apple Distribution:" in details or "Authority=3rd Party Mac Developer Application:" in details,
                        f"Not signed for App Store distribution: {product}")
            else:
                require("Authority=Developer ID Application:" in details, f"Not signed with Developer ID: {product}")
        # Every product embedding ArchiveBoxCore must contain its data, with
        # no independent signature. The enclosing signature seals those bytes.
        resource = contents / "Resources/ArchiveBoxCore_ArchiveBoxCore.bundle" if mac else contents / "ArchiveBoxCore_ArchiveBoxCore.bundle"
        resource_contents = resource / "Contents" if mac else resource
        data = resource_contents / "Resources/public_suffix_list.dat" if mac else resource / "public_suffix_list.dat"
        require(data.is_file(), f"Missing PSL resource: {product}")
        require(not (resource_contents / "_CodeSignature").exists(), f"Independent resource-bundle signature: {resource}")
        print(f"Verified {mode}: {info['CFBundleIdentifier']}")
    # Check independently signed nested code, including bundles and dylibs,
    # against the nearest app/extension's permitted signing certificate.
    for path in app.rglob("*"):
        if path.is_symlink() or not (path.suffix in {".bundle", ".framework", ".dylib", ".xpc"}):
            continue
        details = subprocess.run(["codesign", "-d", str(path)], capture_output=True)
        if details.returncode:
            plist = path / "Contents/Info.plist" if (path / "Contents").is_dir() else path / "Info.plist"
            require(path.suffix == ".bundle" and plist.is_file(), f"Unsigned nested code: {path}")
            require("CFBundleExecutable" not in plistlib.loads(plist.read_bytes()), f"Unsigned executable bundle: {path}")
            continue
        owner = next((p for p in path.parents if p in certificates), None)
        require(owner is not None, f"No signing owner for {path}")
        run("codesign", "--verify", "--strict", str(path))
        require(signing_certificate(path, temporary) == certificates[owner], f"Nested signer differs from enclosing product: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=pathlib.Path, help=".app, .xcarchive, .ipa or .pkg")
    parser.add_argument("--mode", choices=["development", "app-store", "developer-id"], required=True)
    parser.add_argument("--team", default="Q3VA4FKRSA")
    args = parser.parse_args()
    artifact = args.artifact.resolve()
    with tempfile.TemporaryDirectory(prefix="archivebox-signing-") as directory:
        temporary = pathlib.Path(directory)
        if artifact.suffix == ".pkg":
            # Inspect the payload of the exact exported installer. Examining
            # only the .xcarchive misses changes made by distribution export.
            run("pkgutil", "--check-signature", str(artifact))
            root = temporary / "expanded"
            run("pkgutil", "--expand-full", str(artifact), str(root))
        elif artifact.suffix == ".ipa":
            root = temporary / "expanded"
            run("ditto", "-x", "-k", str(artifact), str(root))
        else:
            root = artifact
        apps = [root] if root.suffix == ".app" else list(root.rglob("*.app"))
        apps = [app for app in apps if not any(parent.suffix == ".app" for parent in app.parents)]
        require(len(apps) == 1, f"Expected one top-level app, found {len(apps)} in {artifact}")
        verify(apps[0], args.mode, args.team, temporary)
    print(f"Signing verification passed: {artifact}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors="replace") if isinstance(error, subprocess.CalledProcessError) else str(error)
        raise SystemExit(f"Signing verification failed: {detail}") from error
