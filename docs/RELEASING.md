# Building and releasing Trimsmith

## Prerequisites

- A Mac, Xcode, and command-line tools, with a macOS 14 or later SDK.
- Python 3.9+ and Homebrew tools: `brew install cmake nasm pkg-config gh`.
- Enough local space for two tool builds and the app/DMG (several GB).

Create an isolated DMG packaging environment:

```sh
python3 -m venv build/release-venv
build/release-venv/bin/pip install -r packaging/requirements-release.txt
```

## Bundled tools

```sh
python3 scripts/build-tools.py --arch universal
```

`packaging/tool-sources.json` pins exact FFmpeg, x264, and x265 source archives and SHA-256 checksums. Downloads are checked before extraction. Separate build directories produce arm64 and x86_64 tools with a macOS 14 deployment target. The encoder libraries are linked statically; only system frameworks/libraries remain dynamic. Homebrew FFmpeg and its dylibs are not copied into the app.

This build retains FFmpeg’s built-in demuxers, decoders, filters, and encoders, adds x264 and a 10-bit x265 library, and disables networking and automatic discovery of optional local libraries. Trimsmith’s HEVC exports use 10-bit encoding. Optional external decoders such as libdav1d are not bundled; FFmpeg’s available built-in alternatives remain. No `--enable-nonfree` components are used.

For diagnostics, redirect output to `build/tools.log`. A failed build keeps its files; inspect the failure, then use `--resume` only after fixing its cause. Completed builds carry a source/recipe manifest. Recipe changes require moving old build/output directories aside and rebuilding rather than silently mixing artifacts.

## Local development candidate

```sh
python3 scripts/build-release.py --development --arch universal
```

This creates a self-contained app in a unique `Trimsmith-release-*` folder in the macOS temporary directory and a styled, read-only compressed DMG in `dist/0.1.0-universal-dev/`, alongside a matching tool-source archive and `SHA256SUMS.txt`. These are development candidates, not notarized public downloads. No release is uploaded automatically.

The DMG contains the app, an Applications-folder symlink, and a background with drag instructions. `dmgbuild` writes Finder layout metadata directly; it does not need to manipulate an open Finder window.

Run integration tests using the bundled executables instead of Homebrew:

```sh
TEST_TOOL_DIR="$PWD/build/tools/arm64/bin" ./scripts/test.sh
```

For Intel, run the same test command with the x86_64 tools on an Intel Mac. Cross-compilation and static inspection on Apple Silicon do not substitute for an Intel runtime test. The GitHub checks run the tests on both architectures with locally installed tools; release-tool runtime validation should use the exact bundled builds too.

## Signing and notarization

Create a **Developer ID Application** certificate in Xcode → Settings → Accounts → your paid team → Manage Certificates. Keep its private key in the local Keychain. Check availability with:

```sh
security find-identity -v -p codesigning
```

Store notarization credentials interactively; do not write passwords into the repository or command history:

```sh
xcrun notarytool store-credentials "Trimsmith"
```

Then build a public release candidate:

```sh
SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
NOTARY_PROFILE="Trimsmith" \
python3 scripts/build-release.py --arch universal --version 0.1.0 --build-number 24
```

The pipeline signs nested tools before the app, uses hardened runtime and secure timestamps, checks architecture slices/load paths/deployment targets, notarizes and staples the app, builds/signs/notarizes/staples the DMG, and verifies the disk image. Any failed step stops publication. Artifact directories are not overwritten automatically. Public builds require a clean committed checkout; `BuildInfo.json` records the source revision and build number inside the app.

Notarization credentials and signing identities must be available to the invoking process. Restricted Keychain access can make valid local credentials appear unavailable.

## Source and license materials

Each release includes a `*-tool-sources.tar.xz` containing the exact pristine dependency archives, source pins/checksums, build recipe, generated configuration, manifests, and license texts. Its name and release URL are recorded inside the app under `Contents/Resources/ThirdParty/README.txt`. Distribute this archive together with the corresponding DMG. Do not publish a DMG alone or substitute unrelated upstream source versions.

Original Trimsmith files are 0BSD. FFmpeg/x264/x265 in this configuration are GPL-2.0-or-later. System libraries remain part of macOS. See `THIRD_PARTY.md`; reassess the licenses if build options/dependencies change. App Store distribution is a separate process and licensing review.

## GitHub release

Authenticate as the repository owner (`gh auth login`), then push the tested source to `orrmy/Trimsmith`. Keep release artifacts in GitHub Releases, not Git history. Create the version tag from the exact commit used to build the package, and upload all three artifacts together:

```sh
git tag v0.1.0
git push origin v0.1.0
gh release create v0.1.0 --repo orrmy/Trimsmith --draft \
  --title "Trimsmith 0.1.0" --notes-file docs/RELEASE_NOTES_0.1.0.md \
  dist/0.1.0-universal/*
```

Inspect and test the mounted downloaded DMG, the app copied into Applications, and the source/checksum downloads before publishing the draft. A second Mac without Homebrew is useful for final validation. Verify playback, seeking, importing, both cut modes, codec choices, all audio tracks, cancellation, and quitting. A successful notarization is not a functional test.

The checks workflow runs builds/tests for source changes using `--headless`. This explicitly skips only native AVPlayer frame-step playback, which needs an interactive video session; default local test runs enforce that assertion. FFmpeg frame-count, boundary, and thumbnail comparisons remain enabled on CI. The manually triggered candidate workflow creates unnotarized artifacts for review, without signing secrets or automatically publishing a release. Public signing/notarization currently runs locally.
