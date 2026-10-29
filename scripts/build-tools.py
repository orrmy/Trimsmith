#!/usr/bin/env python3
"""Build pinned, self-contained FFmpeg tools for one or both supported Mac architectures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
SOURCES = BUILD / "tool-sources"


def run(args, cwd=None, env=None):
    """Run a build step with inherited output and stop immediately on failure."""
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def checked_sources(lock):
    """Download missing archives and verify pinned checksums before extracting or running source code."""
    SOURCES.mkdir(parents=True, exist_ok=True)
    for item in lock.values():
        archive = SOURCES / item["archive"]
        if not archive.exists():
            partial = archive.with_suffix(archive.suffix + ".partial")
            try:
                run(["curl", "-fLsS", "--retry", "3", item["url"], "-o", partial])
                partial.replace(archive)
            finally:
                partial.unlink(missing_ok=True)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != item["sha256"]:
            raise SystemExit(f"Checksum mismatch: {archive}; remove it and retry.")


def extract(item, destination):
    """Unpack a checksum-verified source into a fresh, architecture-specific work directory."""
    destination.mkdir(parents=True, exist_ok=True)
    run(["tar", "-xf", SOURCES / item["archive"], "--strip-components", "1", "-C", destination])


def build_arch(arch, lock, jobs, resume=False):
    """Cross-build static codec libraries and tools with a macOS 14 minimum, retaining exact build logs."""
    work = BUILD / "tool-build" / arch
    prefix = work / "prefix"
    out = BUILD / "tools" / arch
    if (out / "manifest.json").exists():
        manifest = json.loads((out / "manifest.json").read_text())
        if manifest.get("sources") == lock and manifest.get("recipe") == hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
            print(f"Using existing verified recipe output for {arch}", flush=True)
            return
        raise SystemExit(f"Build recipe changed: move {work} and {out} aside before rebuilding.")
    if work.exists() and not resume:
        raise SystemExit(f"Partial build exists at {work}; move it aside to retry cleanly.")
    work.mkdir(parents=True, exist_ok=True)
    prefix.mkdir(exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    flags = f"-arch {arch} -mmacosx-version-min=14.0"
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0", PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"))
    # Do not accidentally use Homebrew's libraries for the host architecture.
    env.pop("PKG_CONFIG_PATH", None)
    for name, item in lock.items():
        if not (work / name).exists():
            extract(item, work / name)
    x264 = work / "x264"
    run(["./configure", f"--prefix={prefix}", "--enable-static", "--enable-pic", "--disable-cli",
         "--disable-opencl", f"--host={'aarch64' if arch == 'arm64' else 'x86_64'}-apple-darwin",
         f"--extra-cflags={flags}", f"--extra-ldflags={flags}"], cwd=x264, env=env)
    run(["make", f"-j{jobs}"], cwd=x264, env=env)
    run(["make", "install"], cwd=x264, env=env)
    x265build = work / "x265-build"
    # Trimsmith always encodes HEVC at 10 bits. A single 10-bit library avoids
    # duplicate 8/10/12-bit libraries without limiting FFmpeg's built-in decoders.
    run(["cmake", "-S", work / "x265/source", "-B", x265build,
         "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_BUILD_TYPE=Release",
         "-DCMAKE_SYSTEM_NAME=Darwin", f"-DCMAKE_SYSTEM_PROCESSOR={arch}",
         f"-DCMAKE_OSX_ARCHITECTURES={arch}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
         f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DENABLE_SHARED=OFF", "-DENABLE_CLI=OFF",
         "-DHIGH_BIT_DEPTH=ON", "-DENABLE_LIBNUMA=OFF"] , env=env)
    run(["cmake", "--build", x265build, "--parallel", jobs], env=env)
    run(["cmake", "--install", x265build], env=env)
    ffmpeg = work / "ffmpeg"
    run(["./configure", f"--prefix={prefix}", "--target-os=darwin", f"--arch={arch}",
         "--enable-cross-compile", "--cc=clang", "--cxx=clang++", "--enable-static", "--disable-shared",
         "--disable-autodetect", "--disable-network", "--disable-doc", "--disable-ffplay",
         "--enable-gpl", "--enable-libx264", "--enable-libx265", "--enable-zlib", "--enable-bzlib",
         "--disable-debug", "--enable-videotoolbox", "--enable-audiotoolbox",
         f"--extra-cflags={flags} -I{prefix / 'include'}",
         f"--extra-ldflags={flags} -L{prefix / 'lib'}", f"--extra-cxxflags={flags}", "--extra-libs=-lc++"], cwd=ffmpeg, env=env)
    run(["make", f"-j{jobs}"], cwd=ffmpeg, env=env)
    (out / "bin").mkdir(exist_ok=True)
    for name in ("ffmpeg", "ffprobe"):
        shutil.copy2(ffmpeg / name, out / "bin" / name)
        run(["strip", "-S", out / "bin" / name])
    # Preserve generated configuration as well as pristine source archives.
    shutil.copy2(ffmpeg / "ffbuild/config.log", out / "ffmpeg-config.log")
    shutil.copy2(ffmpeg / "ffbuild/config.mak", out / "ffmpeg-config.mak")
    (out / "manifest.json").write_text(json.dumps({"arch": arch, "minimum_macos": "14.0", "sources": lock,
        "recipe": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}, indent=2) + "\n")
    print(f"Built standalone tools: {out}", flush=True)


def main():
    """Resolve source pins and build selected slices; universal assembly is handled by the app build."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64", "x86_64", "universal"], default="universal")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 4))
    parser.add_argument("--resume", action="store_true", help="Resume a partial build after diagnosing its failure")
    args = parser.parse_args()
    lock = json.loads((ROOT / "packaging/tool-sources.json").read_text())
    checked_sources(lock)
    for arch in (["arm64", "x86_64"] if args.arch == "universal" else [args.arch]):
        build_arch(arch, lock, max(1, args.jobs), args.resume)


if __name__ == "__main__":
    main()
