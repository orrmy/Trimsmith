<p align="center"><img src="Branding/IconConcepts/trimsmith-craftsman-v1.png" width="160" alt="Trimsmith’s bearded film-cutting craftsman"></p>

# Trimsmith

A small, native macOS video cutter. Mark the parts you want to keep, then export them as one file.

- **Lossless cutting:** expands selections to surrounding keyframes and copies streams without further encoding.
- **Frame-exact cutting:** trims decoded frames and exports H.264, 10-bit HEVC, or ProRes, with quality and tune options.
- Native video playback, frame stepping, keyframe navigation, and 0.25×–4× playback speed.
- Automatic selections from IN/OUT points, undo/redo, and before/after boundary previews.
- A separate local working copy for every import; original recordings remain unchanged.
- Every audio track retained, with reviewed conversion when needed for compatibility.

## Download

Release downloads will be published on the [Releases page](https://github.com/orrmy/Trimsmith/releases). Open the DMG and drag Trimsmith into Applications. A self-contained release includes FFmpeg and ffprobe; Homebrew is not required for users.

Requires **macOS 14 or later**. Universal release packaging targets Apple Silicon and Intel. The first public binary release is still being prepared; development candidates are not notarized public releases.

## Quick start

1. Open a video with **Command-O**, drop it on the window or Dock icon, or use Finder’s Open With.
2. Review any conversion or omitted content, then let the working copy and keyframe index finish.
3. Press **I** for IN and **O** for OUT. Selections appear automatically; extra markers remain editable.
4. Choose Lossless or Frame-exact and press **Command-E** to select the output format and encoding settings.

**Space** plays/pauses. **Left/Right** step frames; **Shift-Left/Right** jump keyframes; **Command-Left/Right** select cut points. **1–5** choose speed; **Up/Down** change it. **Backspace** deletes a selected cut point. **Command-Z** undoes edits and deliberate playhead moves.

## Build from source

Install Xcode and its command-line tools. For a quick development build, install FFmpeg (`brew install ffmpeg`) and run:

```sh
./scripts/build.sh
```

The app is written to `build/Trimsmith.app`. There are no downloaded Swift packages. The default build targets the current Mac and uses an ad hoc signature.

For self-contained universal builds, bundled tool sources, DMG creation, Developer ID signing, and notarization, see [Release instructions](docs/RELEASING.md).

## Tests

```sh
./scripts/test.sh
```

Default local runs include native AVPlayer frame stepping. Hosted CI uses `--headless`, explicitly skipping that one interactive playback assertion while keeping decoded-frame export and preview checks.

The tests generate local media and exercise import preservation/conversion, all audio tracks, lossless boundaries, frame-exact encoders, export warnings, safe saving, cancellation, editing history, playback, previews, and document events. See [implementation notes](docs/DESIGN.md) for behavior and limitations. To test bundled tools, set `TEST_TOOL_DIR` as described in the release instructions.

## Current limits

One source file per session; selections export in source order. Edits are held in memory, with no saved project format. Extra video tracks, subtitles, chapters, and attachments are reported as omissions. HDR copying is supported where Apple can play it; HDR encoding is not implemented. Playback compatibility depends on Apple’s media frameworks. Lossless output checks are advisory and cannot guarantee every frame or audio sample in a damaged recording.

## License

Unless otherwise identified, original Trimsmith source, scripts, documentation, and artwork are licensed under [Zero-Clause BSD (0BSD)](LICENSE): reuse and modification are permitted, including commercially, without attribution or source-disclosure requirements. No warranty is provided.

FFmpeg and other third-party components retain their own licenses. GPL-enabled tools are distributed separately from the 0BSD Swift app, with their license texts and matching source/build materials. See [third-party notices](THIRD_PARTY.md).
