# Third-party software

Trimsmith's original project files are licensed under 0BSD; this does not
relicense third-party software distributed with or used by the app.

## FFmpeg and ffprobe

Trimsmith invokes the FFmpeg and ffprobe executables through command-line
arguments, pipes, and media files. It does not currently link FFmpeg libraries
into the Swift application.

FFmpeg is LGPL-2.1-or-later by default. Enabling optional GPL components changes
the applicable license of the FFmpeg build. Our development configuration uses
GPL-enabled FFmpeg with libx264 and libx265; the exact license and obligations
of a distributed build depend on its full configuration and dependencies.

Self-contained releases use the pinned sources in `packaging/tool-sources.json`
and `scripts/build-tools.py`. The selected FFmpeg/x264/x265 configuration is
GPL-2.0-or-later and links the encoder libraries statically into the separate
FFmpeg tools. Only macOS system libraries/frameworks remain dynamic.

The release builder installs per-component license texts and source-availability
information in `Contents/Resources/ThirdParty/`, accessible through the app's
Third-Party Licenses menu. Each DMG is accompanied by a tool-source archive
containing the exact pristine sources, build recipe, configurations, checksums,
and manifests. Distribute that archive alongside its DMG in the same release.
Original source copyright notices remain in those archives. See
[release instructions](docs/RELEASING.md) for the exact process.

Development builds can still discover locally installed tools, whose licenses
and dependencies may differ from the release configuration.

- FFmpeg licensing: https://ffmpeg.org/legal.html
- FFmpeg source and build information: https://ffmpeg.org/download.html

## Licensing boundary

The choice of 0BSD applies to Trimsmith's original files. Bundling separate
programs does not grant permission to remove their notices or redistribute them
under 0BSD. Keep their materials clearly identified in each binary release.

Any later change to link third-party code into the application requires a new
review of the applicable licenses. App Store distribution also needs a separate
review against the selected dependency licenses and the store's terms.
