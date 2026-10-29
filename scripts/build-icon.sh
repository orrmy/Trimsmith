#!/bin/bash
# Package the selected, unchanged portrait into the standard macOS icon sizes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Branding/IconConcepts/trimsmith-craftsman-v1.png"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/trimsmith-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" "$ROOT/Resources"

# Point sizes need both 1x and 2x representations for standard and Retina displays.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  pixels=$((size * 2))
  sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
