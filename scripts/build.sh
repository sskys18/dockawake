#!/bin/bash
# Build DockAwake.app, the dockawake-pmset helper, and the temporary RunCat remover.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/DockAwake.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling helper"
clang -O2 -Wall -Wextra -target arm64-apple-macosx13.0 -o "$BUILD/dockawake-pmset" "$ROOT/src/dockawake-pmset.c"

echo "==> Compiling temporary RunCat remover"
clang -O2 -Wall -Wextra -target arm64-apple-macosx13.0 -o "$BUILD/runcat-safe-remove" "$ROOT/src/runcat-safe-remove.c"

echo "==> Compiling app"
swift_sources=("$ROOT"/src/*.swift)
swiftc -O -target arm64-apple-macosx13.0 -framework Cocoa -framework IOKit -framework SystemConfiguration -o "$APP/Contents/MacOS/DockAwake" "${swift_sources[@]}"

cp "$ROOT/src/Info.plist" "$APP/Contents/Info.plist"

echo "==> Codesigning (ad-hoc)"
codesign --force -s - "$BUILD/dockawake-pmset"
codesign --force -s - "$BUILD/runcat-safe-remove"
codesign --force -s - "$APP"

echo "==> Built: $APP"
