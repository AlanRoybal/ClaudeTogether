#!/usr/bin/env bash
# Fetches prebuilt bore binaries for arm64 and x86_64 macOS,
# lipo-creates a universal binary at macos/Resources/bore.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/macos/Resources/bore"
BORE_VERSION="${BORE_VERSION:-0.5.2}"

if [[ -f "$OUT" ]]; then
  echo "[build-bore] already present at $OUT — skipping (delete to rebuild)"
  exit 0
fi

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

fetch() {
  local triple="$1"
  local url="https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/bore-v${BORE_VERSION}-${triple}.tar.gz"
  echo "[build-bore] fetching $url"
  curl -fL "$url" -o "$TMPDIR_LOCAL/${triple}.tar.gz"
  mkdir -p "$TMPDIR_LOCAL/${triple}"
  tar -xzf "$TMPDIR_LOCAL/${triple}.tar.gz" -C "$TMPDIR_LOCAL/${triple}"
}

fetch aarch64-apple-darwin
fetch x86_64-apple-darwin

ARM_BIN="$(find "$TMPDIR_LOCAL/aarch64-apple-darwin" -type f -name bore -perm +111 | head -1)"
X86_BIN="$(find "$TMPDIR_LOCAL/x86_64-apple-darwin" -type f -name bore -perm +111 | head -1)"

if [[ -z "${ARM_BIN:-}" || -z "${X86_BIN:-}" ]]; then
  echo "[build-bore] failed to locate bore binaries in extracted archives" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$OUT"
chmod +x "$OUT"

echo "[build-bore] universal bore created at $OUT"
lipo -info "$OUT"
ls -lh "$OUT"
