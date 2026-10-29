#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Only the native AVPlayer frame-step assertion requires an interactive desktop.
# Make its omission explicit on hosted runners; normal local runs remain strict.
if [[ $# -eq 1 && "$1" == "--headless" ]]; then
  export TRIMSMITH_HEADLESS_TESTS=1
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--headless]" >&2
  exit 2
fi
ARCH="${TEST_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported test architecture: $ARCH" >&2; exit 1 ;; esac
mkdir -p "$ROOT/build/module-cache"

xcrun swiftc -swift-version 5 -target "$ARCH-apple-macosx14.0" -g -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/MediaEngine.swift" "$ROOT/Sources/ImportEngine.swift" "$ROOT/Tests/TestSupport.swift" "$ROOT/Tests/EngineTests.swift" -o "$ROOT/build/engine-tests"
"$ROOT/build/engine-tests" "$ROOT/build/test-media"
xcrun swiftc -swift-version 5 -target "$ARCH-apple-macosx14.0" -g -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/MediaEngine.swift" "$ROOT/Sources/ImportEngine.swift" "$ROOT/Tests/TestSupport.swift" "$ROOT/Tests/ImportTests.swift" -o "$ROOT/build/import-tests"
"$ROOT/build/import-tests" "$ROOT/build/test-media"
xcrun swiftc -swift-version 5 -target "$ARCH-apple-macosx14.0" -g -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/MediaEngine.swift" "$ROOT/Sources/ImportEngine.swift" "$ROOT/Sources/BoundaryPreview.swift" "$ROOT/Sources/EditorModel.swift" "$ROOT/Sources/ExportControls.swift" "$ROOT/Sources/AppDelegate.swift" \
  "$ROOT/Tests/TestSupport.swift" "$ROOT/Tests/EditorTests.swift" -o "$ROOT/build/editor-tests"
"$ROOT/build/editor-tests" "$ROOT/build/test-media"
xcrun swiftc -swift-version 5 -target "$ARCH-apple-macosx14.0" -g -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/MediaEngine.swift" "$ROOT/Sources/BoundaryPreview.swift" "$ROOT/Tests/TestSupport.swift" "$ROOT/Tests/BoundaryPreviewTests.swift" -o "$ROOT/build/preview-tests"
"$ROOT/build/preview-tests" "$ROOT/build/test-media"
