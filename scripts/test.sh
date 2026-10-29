#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
