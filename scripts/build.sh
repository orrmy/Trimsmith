#!/bin/bash
# Build a development app, or a self-contained app when TOOL_ARCHS names built tool slices.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP_OUTPUT:-$ROOT/build/Trimsmith.app}"
ARCHS="${ARCHS:-$(uname -m)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-22}"
IDENTITY="${SIGN_IDENTITY:--}"
if [[ ! "$ROOT/Resources/AppIcon.icns" -nt "$ROOT/Branding/IconConcepts/trimsmith-craftsman-v1.png" ]]; then
  "$ROOT/scripts/build-icon.sh"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
# Compile each architecture separately; lipo combines complete Mach-O slices.
SLICES=()
for arch in $ARCHS; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
  SLICE="$ROOT/build/Trimsmith-$arch"
  xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx14.0" \
    -module-cache-path "$ROOT/build/module-cache" \
    "$ROOT/Sources/MediaEngine.swift" "$ROOT/Sources/ImportEngine.swift" "$ROOT/Sources/BoundaryPreview.swift" \
    "$ROOT/Sources/EditorModel.swift" "$ROOT/Sources/ExportControls.swift" "$ROOT/Sources/AppDelegate.swift" \
    "$ROOT/Sources/EditorControls.swift" "$ROOT/Sources/TrimsmithApp.swift" -o "$SLICE"
  SLICES+=("$SLICE")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Trimsmith"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# A fresh plist is generated on every build so versions and executable names cannot drift.
/usr/bin/python3 - "$APP" "$VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib, sys
from pathlib import Path
app, version, build = sys.argv[1:]
info = {
    'CFBundleExecutable': 'Trimsmith', 'CFBundleIdentifier': 'local.framecut.app',
    'CFBundleName': 'Trimsmith', 'CFBundleDisplayName': 'Trimsmith', 'CFBundleIconFile': 'AppIcon',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version, 'CFBundleVersion': build,
    'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True,
    'CFBundleDocumentTypes': [
        {'CFBundleTypeName': 'Trimsmith Video', 'CFBundleTypeRole': 'Viewer', 'LSHandlerRank': 'Alternate',
         'LSItemContentTypes': ['public.movie', 'public.video'], 'CFBundleTypeExtensions': ['mp4', 'mov', 'm4v']},
        {'CFBundleTypeName': 'Video for Local Import', 'CFBundleTypeRole': 'Viewer', 'LSHandlerRank': 'Alternate',
         'CFBundleTypeExtensions': ['mkv', 'ts', 'mts', 'm2ts', 'avi', 'webm', 'mpg', 'mpeg', 'vob', 'flv', 'mxf', 'wmv']}
    ]
}
(Path(app) / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
if [[ -n "${TOOL_ARCHS:-}" ]]; then
  mkdir -p "$APP/Contents/Resources/bin"
  for tool in ffmpeg ffprobe; do
    TOOLS=()
    for arch in $TOOL_ARCHS; do TOOLS+=("$ROOT/build/tools/$arch/bin/$tool"); done
    lipo -create "${TOOLS[@]}" -output "$APP/Contents/Resources/bin/$tool"
  done
elif [[ -d "$APP/Contents/Resources/bin" ]]; then
  echo "Refusing a development build over an app with bundled tools. Choose a fresh APP_OUTPUT." >&2
  exit 1
fi
if [[ -n "${EXTRA_RESOURCES:-}" ]]; then
  ditto "$EXTRA_RESOURCES" "$APP/Contents/Resources"
fi
xattr -cr "$APP"
# Sign nested executables first; --deep signing can hide mistakes in nested components.
if [[ -d "$APP/Contents/Resources/bin" ]]; then
  for tool in ffmpeg ffprobe; do
    if [[ "$IDENTITY" == "-" ]]; then
      codesign --force --sign - "$APP/Contents/Resources/bin/$tool"
    else
      codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP/Contents/Resources/bin/$tool"
    fi
  done
fi
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
