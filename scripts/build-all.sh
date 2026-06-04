#!/usr/bin/env bash
# End-to-end build: bore binary -> zig core -> xcodegen -> xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-$HOME/.local/bin/zig}"
XCODEGEN="${XCODEGEN:-$HOME/.local/bin/xcodegen}"

echo "==> 1/4 bundle bore"
./scripts/build-bore.sh

echo "==> 2/4 build Zig core"
(cd core && "$ZIG" build -Doptimize=ReleaseSafe)
# Zig 0.16's archiver writes .a members that Apple's ld rejects as "not
# 8-byte aligned" (and stored with mode 0000). Repackage with libtool so the
# Swift link step accepts it. Don't copy core/zig-out/lib/*.a directly.
REPACK="$(mktemp -d)"
( cd "$REPACK" \
  && ar x "$ROOT/core/zig-out/lib/libcollabterm.a" \
  && chmod 644 ./*.o \
  && xcrun libtool -static -o libcollabterm.a ./*.o )
cp "$REPACK/libcollabterm.a"                  macos/Vendor/
cp core/zig-out/include/collabterm.h          macos/Vendor/
rm -rf "$REPACK"

echo "==> 3/4 xcodegen"
(cd macos && "$XCODEGEN" generate)

echo "==> 4/4 xcodebuild"
xcodebuild \
  -project macos/CoTTY.xcodeproj \
  -scheme CoTTY \
  -configuration Debug \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  build | xcbeautify 2>/dev/null || \
xcodebuild \
  -project macos/CoTTY.xcodeproj \
  -scheme CoTTY \
  -configuration Debug \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  build

APP="$ROOT/build/Build/Products/Debug/CoTTY.app"
if [[ -d "$APP" ]]; then
  echo ""
  echo "==> .app built at: $APP"
  echo "==> open with: open '$APP'"
fi
