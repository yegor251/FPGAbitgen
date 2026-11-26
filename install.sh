#!/usr/bin/env bash
# FPGAbitgen installer: archive from an argument, or from a URL.
#   ./install.sh fpgabitgen-2026.11.25-darwin-arm64.tar.xz
#   ./install.sh https://github.com/<you>/FPGAbitgen/releases/download/v1.0/....
# Installs to ~/.local/share/fpgabitgen and symlinks ~/.local/bin/bitgen.
set -euo pipefail

INSTALL_ROOT=${BITGEN_HOME:-$HOME/.local/share/fpgabitgen}
BIN_DIR=${BITGEN_BIN:-$HOME/.local/bin}

die() { echo "install.sh: $*" >&2; exit 1; }

ARCHIVE=${1:-}
if [ -z "$ARCHIVE" ]; then
    die "укажите архив: ./install.sh <bitgen-*.tar.xz> (или URL на release)"
fi

mkdir -p "$INSTALL_ROOT" "$BIN_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

case "$ARCHIVE" in
    http*://*)
        echo "Скачивание $ARCHIVE"
        curl -fsSL -o "$WORK/fpgabitgen.tar.xz" "$ARCHIVE"
        ;;
    *)
        [ -f "$ARCHIVE" ] || die "архив не найден: $ARCHIVE"
        cp "$ARCHIVE" "$WORK/fpgabitgen.tar.xz"
        ;;
esac

echo "Установка в $INSTALL_ROOT"
rm -rf "$INSTALL_ROOT.old"
[ -d "$INSTALL_ROOT" ] && mv "$INSTALL_ROOT" "$INSTALL_ROOT.old"
tar -xJf "$WORK/fpgabitgen.tar.xz" -C "$WORK"
SRC=$(find "$WORK" -maxdepth 1 -type d -name 'fpgabitgen-*' | head -1)
mv "$SRC" "$INSTALL_ROOT"

# macOS Gatekeeper: снимаем карантинную метку со скачанных файлов
if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$INSTALL_ROOT" 2>/dev/null || true
fi

ln -sf "$INSTALL_ROOT/bin/bitgen" "$BIN_DIR/bitgen"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "ВНИМАНИЕ: $BIN_DIR нет в PATH — добавьте в ~/.zshrc:" >&2
       echo "  export PATH=\"$BIN_DIR:\$PATH\"" >&2 ;;
esac

"$BIN_DIR/bitgen" --version
echo "Готово. Использование: bitgen <design.vhd> -o out.bit"
