First public version of Trimsmith, a focused native macOS video cutter.

- Lossless keyframe cutting and frame-exact H.264, 10-bit HEVC, and ProRes export.
- Automatic selections, undo/redo, frame and keyframe navigation, adjustable playback speed, and before/after cut previews.
- Local working copies, reviewed compatibility conversions, and preservation of every audio track.
- Self-contained Mac app with bundled FFmpeg/ffprobe; no Homebrew setup required.

Requires macOS 14 or later. Open the DMG and drag Trimsmith into Applications.

The `tool-sources.tar.xz` asset contains matching sources and build materials for the bundled GPL tools. Original Trimsmith files are licensed under 0BSD. Verify downloads with `SHA256SUMS.txt`.

Known limits: one source at a time, edits held in memory, no HDR encoding, and no subtitle/chapter/extra-video export. Lossless checks warn about possible problems but do not guarantee damaged recordings will play correctly. See the README for details.
