#!/usr/bin/env python3
"""Create a self-contained DMG and matching tool-source archive; public builds require notarization."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(args, env=None):
    """Run a release step without shell interpolation, failing the release on any error."""
    subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env, check=True)


def source_materials(work, arches, version, label):
    """Assemble exact dependency sources, build recipes/configuration, and per-component license notices."""
    lock = json.loads((ROOT / "packaging/tool-sources.json").read_text())
    material = work / "tool-sources"
    material.mkdir()
    for item in lock.values():
        shutil.copy2(ROOT / "build/tool-sources" / item["archive"], material / item["archive"])
    shutil.copy2(ROOT / "packaging/tool-sources.json", material)
    shutil.copy2(ROOT / "scripts/build-tools.py", material)
    shutil.copy2(ROOT / "LICENSE", material / "Trimsmith-build-recipe-LICENSE")
    metadata = work / "resources/ThirdParty"
    metadata.mkdir(parents=True)
    for component in lock:
        source = ROOT / "build/tool-build" / arches[0] / component
        license_file = source / ("COPYING.GPLv2" if component == "ffmpeg" else "COPYING")
        shutil.copy2(license_file, metadata / f"{component}-LICENSE.txt")
    for arch in arches:
        dest = material / arch
        dest.mkdir()
        for name in ("manifest.json", "ffmpeg-config.log", "ffmpeg-config.mak"):
            shutil.copy2(ROOT / "build/tools" / arch / name, dest)
        for name, file in [("x264-config.mak", "x264/config.mak"), ("x265-CMakeCache.txt", "x265-build/CMakeCache.txt")]:
            shutil.copy2(ROOT / "build/tool-build" / arch / file, dest / name)
    source_name = f"Trimsmith-{version}-{label}-tool-sources.tar.xz"
    (metadata / "README.txt").write_text(
        "Trimsmith uses FFmpeg and ffprobe as separate command-line tools.\n"
        "FFmpeg is built with GPL components, including x264 and x265.\n"
        "These tools are distributed under GPL version 2 or later; the original\n"
        "Trimsmith files are licensed separately under 0BSD. See the license texts here.\n\n"
        "Corresponding source archives, build recipe, pinned checksums, and configuration:\n"
        f"https://github.com/orrmy/Trimsmith/releases/download/v{version}/{source_name}\n"
        "The source archive is also supplied beside the DMG in the same release.\n"
        "FFmpeg: https://ffmpeg.org/\nx264: https://www.videolan.org/developers/x264.html\n"
        "x265: https://www.videolan.org/developers/x265.html\n")
    shutil.copy2(ROOT / "packaging/tool-sources.json", metadata)
    shutil.copytree(metadata, material / "licenses")
    shutil.copy2(ROOT / "LICENSE", work / "resources/Trimsmith-LICENSE.txt")
    archive = work / source_name
    with tarfile.open(archive, "w:xz") as tar:
        tar.add(material, arcname="Trimsmith-tool-sources")
    return archive


def main():
    """Build tools/app, add license materials before signing, notarize if public, and package a styled DMG."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64", "x86_64", "universal"], default="universal")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--build-number", default="25")
    parser.add_argument("--development", action="store_true", help="Explicitly allow an unnotarized local candidate")
    args = parser.parse_args()
    if not args.version or any(c not in "0123456789." for c in args.version):
        parser.error("Version must contain only digits and dots")
    identity = os.environ.get("SIGN_IDENTITY", "-")
    profile = os.environ.get("NOTARY_PROFILE")
    if not args.development and (identity == "-" or not profile):
        parser.error("Public releases require SIGN_IDENTITY and a Keychain NOTARY_PROFILE; use --development for a local candidate")
    arches = ["arm64", "x86_64"] if args.arch == "universal" else [args.arch]
    venv = ROOT / "build/release-venv/bin/python3"
    if not venv.exists():
        parser.error("Create build/release-venv and install packaging/requirements-release.txt first; see docs/RELEASING.md")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip())
    if not args.development and dirty:
        parser.error("Commit source changes before building a public release")
    label = args.arch + ("-dev" if args.development else "")
    dist = ROOT / "dist" / f"{args.version}-{label}"
    if dist.exists():
        parser.error(f"Artifact directory already exists: {dist}; move it aside before rebuilding")
    run([sys.executable, ROOT / "scripts/build-tools.py", "--arch", args.arch])
    # Documents may be managed by a file provider that adds FinderInfo after
    # signing. Assemble outside it so the sealed app remains unchanged.
    work = Path(tempfile.mkdtemp(prefix="Trimsmith-release-"))
    source = source_materials(work, arches, args.version, label)
    (work / "resources/BuildInfo.json").write_text(json.dumps({"revision": revision, "dirty": dirty,
        "version": args.version, "build": args.build_number, "architectures": arches}, indent=2) + "\n")
    app = work / "Trimsmith.app"
    env = dict(os.environ, APP_OUTPUT=str(app), ARCHS=" ".join(arches), TOOL_ARCHS=" ".join(arches),
               VERSION=args.version, BUILD_NUMBER=args.build_number, SIGN_IDENTITY=identity,
               EXTRA_RESOURCES=str(work / "resources"))
    run([ROOT / "scripts/build.sh"], env=env)
    run([sys.executable, ROOT / "scripts/verify-bundle.py", app, "--arch", *arches])
    if not args.development:
        # Staple the app itself as well as the final DMG so copied applications
        # retain an offline ticket independently of the mounted download.
        zipped = work / "Trimsmith.zip"
        run(["ditto", "-c", "-k", "--keepParent", app, zipped])
        run(["xcrun", "notarytool", "submit", zipped, "--keychain-profile", profile, "--wait"])
        run(["xcrun", "stapler", "staple", app])
        run(["spctl", "--assess", "--type", "execute", "--verbose", app])
    background = work / "background.png"
    renderer = ROOT / "build/dmg-background"
    run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", ROOT / "build/module-cache", ROOT / "packaging/dmg-background.swift", "-o", renderer])
    run([renderer, background])
    dmg = work / f"Trimsmith-{args.version}-{label}.dmg"
    run([venv, "-m", "dmgbuild", "-s", ROOT / "packaging/dmg-settings.py", "-D", f"app={app}",
         "-D", f"background={background}", "Trimsmith", dmg])
    if not args.development:
        run(["codesign", "--sign", identity, "--timestamp", dmg])
        run(["xcrun", "notarytool", "submit", dmg, "--keychain-profile", profile, "--wait"])
        run(["xcrun", "stapler", "staple", dmg])
        run(["xcrun", "stapler", "validate", dmg])
    run(["hdiutil", "verify", dmg])
    # Do not silently overwrite a previous release candidate or signed artifact.
    dist.mkdir(parents=True, exist_ok=False)
    for file in (dmg, source):
        shutil.copy2(file, dist / file.name)
    (dist / "SHA256SUMS.txt").write_text("".join(
        f"{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.name}\n" for file in (dist / dmg.name, dist / source.name)))
    print(f"Release artifacts: {dist}\nApp for local testing: {app}")
    if args.development:
        print("DEVELOPMENT CANDIDATE: not notarized; do not publish as the signed release.")


if __name__ == "__main__":
    main()
