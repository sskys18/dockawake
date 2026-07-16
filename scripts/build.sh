#!/bin/bash
# Build DockAwake.app and the dockawake-pmset helper into build/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/DockAwake.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling helper"
clang -O2 -Wall -Wextra -o "$BUILD/dockawake-pmset" "$ROOT/src/dockawake-pmset.c"

echo "==> Compiling app"
swiftc -O -o "$APP/Contents/MacOS/DockAwake" "$ROOT/src/main.swift"

cp "$ROOT/src/Info.plist" "$APP/Contents/Info.plist"

echo "==> Codesigning (ad-hoc)"
codesign --force -s - "$BUILD/dockawake-pmset"
codesign --force -s - "$APP"

echo "==> Built: $APP"
