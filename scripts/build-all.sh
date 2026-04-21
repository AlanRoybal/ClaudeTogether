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
cp core/zig-out/lib/libcollabterm.a          macos/Vendor/
cp core/zig-out/include/collabterm.h         macos/Vendor/

echo "==> 3/4 xcodegen"
(cd macos && "$XCODEGEN" generate)

echo "==> 4/4 xcodebuild"
xcodebuild \
  -project macos/ClaudeTogether.xcodeproj \
  -scheme ClaudeTogether \
  -configuration Debug \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  build | xcbeautify 2>/dev/null || \
xcodebuild \
  -project macos/ClaudeTogether.xcodeproj \
  -scheme ClaudeTogether \
  -configuration Debug \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  build

APP="$ROOT/build/Build/Products/Debug/ClaudeTogether.app"
if [[ -d "$APP" ]]; then
  echo ""
  echo "==> .app built at: $APP"
  echo "==> open with: open '$APP'"
fi
