#!/usr/bin/env bash
# Packages ./prefix into a distributable archive (run after ./build.sh).
set -euo pipefail
cd "$(dirname "$0")"
PREFIX=${1:-./prefix}
[ -f "$PREFIX/bin/bitgen" ] || { echo "нет prefix с собранным bitgen (запустите ./build.sh)" >&2; exit 1; }
VER=$(cat "$PREFIX/share/VERSION" 2>/dev/null || echo dev)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
NAME="fpgabitgen-$VER-$OS-$ARCH"
OUT="${2:-dist}"
mkdir -p "$OUT"
STAGE=$(mktemp -d)
mkdir "$STAGE/$NAME"
cp -R "$PREFIX/bin" "$PREFIX/tools" "$PREFIX/share" "$STAGE/$NAME/"
tar -cJf "$OUT/$NAME.tar.xz" -C "$STAGE" "$NAME"
( cd "$OUT" && shasum -a 256 "$NAME.tar.xz" >> SHA256SUMS )
echo "$OUT/$NAME.tar.xz"
