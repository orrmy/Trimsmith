#!/usr/bin/env python3
"""Reject release bundles that depend on local libraries or omit requested architecture slices."""
import argparse
from pathlib import Path
import plistlib
import subprocess


def output(args):
    """Capture a short inspection command, propagating errors instead of accepting incomplete output."""
    return subprocess.check_output([str(arg) for arg in args], text=True)


def verify(app, arches):
    """Check every shipped executable's architecture, load paths, minimum OS, and code signature."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["LSMinimumSystemVersion"] == "14.0"
    for relative in ("Contents/MacOS/Trimsmith", "Contents/Resources/bin/ffmpeg", "Contents/Resources/bin/ffprobe"):
        binary = app / relative
        actual = set(output(["lipo", "-archs", binary]).split())
        if actual != set(arches):
            raise SystemExit(f"Wrong architectures in {binary}: {actual}")
        # Only OS-provided dylibs/frameworks may remain dynamic. Static encoder
        # libraries must not leave any /opt/homebrew or build-machine load paths.
        for line in output(["otool", "-L", binary]).splitlines():
            if "(compatibility version" not in line:
                continue
            dependency = line.strip().split(" (", 1)[0]
            if not dependency.startswith(("/System/Library/", "/usr/lib/")):
                raise SystemExit(f"Non-system dependency in {binary}: {dependency}")
        build = output(["vtool", "-show-build", binary])
        minimums = [line.split()[-1] for line in build.splitlines() if line.strip().startswith("minos ")]
        if len(minimums) != len(arches) or any(float(version.rsplit('.', 1)[0] if version.count('.') > 1 else version) > 14 for version in minimums):
            raise SystemExit(f"Unexpected deployment target in {binary}: {minimums}")
    output(["codesign", "--verify", "--deep", "--strict", app])
    print(f"Verified self-contained {', '.join(arches)} bundle: {app}")


def main():
    """Inspect the supplied release bundle before it can be packaged or uploaded."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--arch", nargs="+", choices=["arm64", "x86_64"], required=True)
    args = parser.parse_args()
    verify(args.app.resolve(), args.arch)


if __name__ == "__main__":
    main()
