#!/usr/bin/env bash
# bitgen superbuild: assembles a self-contained bitgen prefix.
#
#   ./build.sh [--prefix DIR] [--suite DIR] [--jobs N] [--clean]
#
# Components:
#   ghdl + yosys  — reused from the OSS CAD Suite install (relocatable bundle)
#   nextpnr       — built from openXC7/nextpnr (pinned hash, xilinx uarch)
#   fpga-as       — built from lromor/fpga-assembler (pinned hash, bazel)
#   chipdb        — generated from openXC7/prjxray-db (pinned hash, artix7)
#   bin/bitgen    — the CLI driver (from this repo)
set -euo pipefail

cd "$(dirname "$0")"
REPO=$(pwd)

PREFIX=$REPO/prefix
SUITE=${BITGEN_SUITE:-$HOME/fpga/oss-cad-suite}
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
SRC=$REPO/src
CLEAN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX=$2; shift 2 ;;
        --suite)  SUITE=$2;  shift 2 ;;
        --jobs)   JOBS=$2;   shift 2 ;;
        --dies)   DIES=$2;   shift 2 ;;
        --clean)  CLEAN=1;   shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

OS=$(uname -s)
ARCH=$(uname -m)
if [ "$OS" != "Darwin" ]; then
    echo "build.sh: пока поддерживается только macOS (бандлинг dylib через otool)" >&2
    exit 1
fi

# ВНИМАНИЕ: не откатывать на 42d06c5f (merge #212) — там регрессия
# package_info assert на пакетах cpg236 (падает P&R для Basys3)
NEXTPNR_HASH=8ad136c27e57448306de7a1bd09d81f31018c71e
PRJXRAY_DB_HASH=0c3504f26f5cf77b6a7605c7bc83ebe1ac67b26f
FPGA_ASSEMBLER_HASH=4939337a337c91e0e236aa94a66cc71ac516ff44
BAZEL_VERSION=9.1.1

# die-кристаллы для генерации chipdb (part на плате = die + корпус + скорость);
# xc7a35t обслуживается базой xc7a50t и т.п. — алиасы резолвит сам bin/bitgen
DIES=${BITGEN_DIES:-xc7a50t}
# части (part) для которых создаются chipdb-алиасы по имени части;
# имя файла chipdb-<part-без-скорости>.bin задаёт корпус при P&R
PARTS=${BITGEN_PARTS:-xc7a35tcpg236-1 xc7a35tcsg324-1}

family_for_die() {
    case "$1" in
        xc7a*) echo artix7 ;;
        xc7k*) echo kintex7 ;;
        xc7s*) echo spartan7 ;;
        xc7z*) echo zynq7 ;;
        *) return 1 ;;
    esac
}

[ -x "$SUITE/bin/yosys" ] || { echo "OSS CAD Suite не найдена: $SUITE (укажите --suite)" >&2; exit 1; }

if [ "$CLEAN" = 1 ]; then rm -rf "$PREFIX" "$SRC"; fi
mkdir -p "$PREFIX"/{bin,share/chipdb} "$PREFIX/tools"/{bin,libexec,lib,share} "$SRC"

say() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------- 1. ghdl+yosys
say "1/6 Бандлинг ghdl+yosys из OSS CAD Suite"
python3 etc/bundle_dylibs.py --root "$PREFIX/tools" \
    --exe "$SUITE/libexec/yosys"      --dest "$PREFIX/tools/libexec" \
    --exe "$SUITE/libexec/ghdl"       --dest "$PREFIX/tools/libexec" \
    --exe "$SUITE/libexec/ghdl1-llvm" --dest "$PREFIX/tools/libexec" \
    --exe "$SUITE/libexec/yosys-abc"  --dest "$PREFIX/tools/libexec" \
    --also "$SUITE/share/yosys/plugins/ghdl.so" --origin "$SUITE/libexec" \
    --also "$SUITE/lib/libncurses.6.dylib"      --origin "$SUITE/libexec"
cp -R "$SUITE/share/yosys" "$PREFIX/tools/share/yosys"
cp -R "$SUITE/lib/ghdl"    "$PREFIX/tools/lib/ghdl"
# keep only the plugin we use (slang/eqy не нужны)
find "$PREFIX/tools/share/yosys/plugins" -type f ! -name 'ghdl.so' -delete 2>/dev/null || true

# --------------------------------------------------------------- 2. nextpnr
say "2/6 Сборка nextpnr (openXC7 форк, $NEXTPNR_HASH)"
if [ ! -d "$SRC/nextpnr" ]; then
    git clone --recursive -j4 https://github.com/openXC7/nextpnr "$SRC/nextpnr"
fi
git -C "$SRC/nextpnr" fetch origin --tags 2>/dev/null || true
git -C "$SRC/nextpnr" checkout -- . 2>/dev/null || true
git -C "$SRC/nextpnr" checkout "$NEXTPNR_HASH"
git -C "$SRC/nextpnr" submodule update --init --recursive 2>/dev/null || true
rm -rf "$SRC/nextpnr/build"
# Darwin: brew llvm clang + libomp (Apple clang не поддерживает -fopenmp)
if [ "$OS" = "Darwin" ]; then
    LLVM_P=$(brew --prefix llvm); LIBOMP_P=$(brew --prefix libomp)
    export CC="$LLVM_P/bin/clang" CXX="$LLVM_P/bin/clang++"
    export CPATH="$LIBOMP_P/include${CPATH:+:$CPATH}"
    export LIBRARY_PATH="$LIBOMP_P/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
    # статический boost_iostreams от brew требует libzstd на линковке
    command -v brew >/dev/null && brew list zstd >/dev/null 2>&1 || brew install zstd >/dev/null 2>&1 || true
    ZSTD_P=$(brew --prefix zstd 2>/dev/null || true)
    EXTRA_CMAKE=(-DCMAKE_EXE_LINKER_FLAGS="-L${ZSTD_P:-/opt/homebrew/opt/zstd}/lib -lzstd")
else
    EXTRA_CMAKE=()
fi
STATIC_OPTS=(-DBoost_USE_STATIC_LIBS=ON -DZLIB_USE_STATIC_LIBS=ON)
if ! cmake -S "$SRC/nextpnr" -B "$SRC/nextpnr/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX/tools" \
        -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
        -DHIMBAECHEL_PRJXRAY_DB="$SRC/prjxray-db" \
        -DHIMBAECHEL_XILINX_DEVICES= -DUSE_OPENMP=ON \
        -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF "${STATIC_OPTS[@]}" \
        "${EXTRA_CMAKE[@]}" > "$SRC/static-configure.log" 2>&1; then
    echo "static boost/zlib не взялся — пересборка с динамическими (лог: $SRC/static-configure.log)"
    rm -rf "$SRC/nextpnr/build"
    cmake -S "$SRC/nextpnr" -B "$SRC/nextpnr/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX/tools" \
        -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
        -DHIMBAECHEL_PRJXRAY_DB="$SRC/prjxray-db" \
        -DHIMBAECHEL_XILINX_DEVICES= -DUSE_OPENMP=ON \
        -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF "${EXTRA_CMAKE[@]}"
fi
cmake --build "$SRC/nextpnr/build" --parallel "$JOBS"
# (см. конфиг: на Darwin LLVM clang + libomp — Apple clang не знает -fopenmp)
cp "$SRC/nextpnr/build/nextpnr-himbaechel" "$PREFIX/tools/bin/"
cp "$SRC/nextpnr/build/bba/bbasm"          "$PREFIX/tools/bin/"
cp "$SRC/nextpnr/.github/scripts/nextpnr-xilinx-shim.sh" "$PREFIX/tools/bin/nextpnr-xilinx"
chmod 755 "$PREFIX/tools/bin/nextpnr-xilinx"

# ------------------------------------------------------------ 3. prjxray-db
FAMILIES=$(for d in $DIES; do family_for_die "$d"; done | sort -u)
say "3/6 База prjxray-db ($PRJXRAY_DB_HASH), семейства: $FAMILIES"
if [ ! -d "$SRC/prjxray-db" ]; then
    git clone --filter=blob:none --no-checkout \
        https://github.com/openXC7/prjxray-db "$SRC/prjxray-db"
    git -C "$SRC/prjxray-db" sparse-checkout init --cone
fi
git -C "$SRC/prjxray-db" sparse-checkout set $FAMILIES
if ! git -C "$SRC/prjxray-db" cat-file -e "$PRJXRAY_DB_HASH" 2>/dev/null; then
    git -C "$SRC/prjxray-db" fetch origin "$PRJXRAY_DB_HASH" 2>/dev/null || true
fi
if git -C "$SRC/prjxray-db" cat-file -e "$PRJXRAY_DB_HASH" 2>/dev/null; then
    git -C "$SRC/prjxray-db" checkout "$PRJXRAY_DB_HASH"
else
    git -C "$SRC/prjxray-db" checkout master
    echo "ВНИМАНИЕ: пин базы недоступен, использую master" >&2
fi
mkdir -p "$PREFIX/tools/share/prjxray-db"
for fam in $FAMILIES; do
    rm -rf "$PREFIX/tools/share/prjxray-db/$fam"
    cp -R "$SRC/prjxray-db/$fam" "$PREFIX/tools/share/prjxray-db/$fam"
done

# -------------------------------------------------------------- 4. fpga-as
say "4/6 Сборка fpga-as ($FPGA_ASSEMBLER_HASH)"
if [ ! -d "$SRC/fpga-assembler" ]; then
    git clone https://github.com/lromor/fpga-assembler "$SRC/fpga-assembler"
fi
git -C "$SRC/fpga-assembler" fetch origin 2>/dev/null || true
git -C "$SRC/fpga-assembler" checkout "$FPGA_ASSEMBLER_HASH"

BAZEL=${BITGEN_BAZEL:-}
if [ -z "$BAZEL" ]; then
    if command -v bazel >/dev/null 2>&1; then BAZEL=$(command -v bazel)
    elif [ -x "$HOME/openxc7/bin/bazel" ]; then BAZEL=$HOME/openxc7/bin/bazel
    fi
fi
if [ -z "$BAZEL" ]; then
    case "$OS/$(uname -m)" in
        Darwin/arm64)  plat=darwin-arm64;  sha=2db883718453f0437a7bcb408e889dbf8539cdc4d61c8ebc3807a1a88d02ff08 ;;
        Darwin/x86_64) plat=darwin-x86_64; sha=6fd490084bdccf044d7a6d8360a26f8770fa09f4e624328efea292f493204930 ;;
        Linux/x86_64)  plat=linux-x86_64;  sha=857bed5d2756b4d998d3caebf2d941d13d434c4eda4b1d6d7dda205736c25a93 ;;
        Linux/aarch64) plat=linux-arm64;   sha=82d1163884e45a6a7ff764cc01197b1b1ed497000726b84dc4b47c1dfc8a2bb4 ;;
    esac
    mkdir -p "$PREFIX/bin"
    curl -fsSL -o "$PREFIX/bin/bazel.tmp" \
        "https://github.com/bazelbuild/bazel/releases/download/$BAZEL_VERSION/bazel-$BAZEL_VERSION-$plat"
    echo "$sha  $PREFIX/bin/bazel.tmp" | shasum -a 256 -c - >/dev/null
    mv "$PREFIX/bin/bazel.tmp" "$PREFIX/bin/bazel"
    chmod 755 "$PREFIX/bin/bazel"
    BAZEL="$PREFIX/bin/bazel"
fi
( cd "$SRC/fpga-assembler" && "$BAZEL" build //fpga:fpga-as -c opt --curses=no --jobs="$JOBS" )
cp "$SRC/fpga-assembler/bazel-bin/fpga/fpga-as" "$PREFIX/tools/bin/"

# ---------------------------------------------------------------- 5. chipdb
say "5/6 Генерация chipdb: die $DIES, части $PARTS"
PY=$SUITE/py3bin/python3
command -v "$PY" >/dev/null 2>&1 || PY=$(command -v pypy3 || command -v python3)
for die in $DIES; do
    fam=$(family_for_die "$die")
    "$PY" "$SRC/nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py" \
        --xray "$SRC/prjxray-db/$fam" --device "$die" \
        --bba "$PREFIX/share/chipdb-$die.bba"
    "$PREFIX/tools/bin/bbasm" -l "$PREFIX/share/chipdb-$die.bba" \
        "$PREFIX/share/chipdb/chipdb-$die.bin"
    rm -f "$PREFIX/share/chipdb-$die.bba"
done
# алиасы по частям: shim получает --device из имени файла,
# bare-die имя оставляет корпус неопределённым (assert package_info)
PYDIE='import re,sys;m=re.match(r"^(xc7[a-z]?[0-9]+t)",sys.argv[1]);d=m.group(1) if m else sys.argv[1];a={"xc7a35t":"xc7a50t","xc7z007s":"xc7z010","xc7z012s":"xc7z010","xc7z014s":"xc7z010"};print(a.get(d,d))'
for part in $PARTS; do
    dbpart=${part%-*}
    die=$(python3 -c "$PYDIE" "$part")
    if ! [ -f "$PREFIX/share/chipdb/chipdb-$die.bin" ]; then
        echo "ВНИМАНИЕ: part $part требует die $die, которого нет в --dies — пропускаю" >&2
        continue
    fi
    cp "$PREFIX/share/chipdb/chipdb-$die.bin" "$PREFIX/share/chipdb/chipdb-$dbpart.bin"
done

# ------------------------------------------------------------- 6. драйвер
say "6/6 Установка CLI"
cp bin/bitgen "$PREFIX/bin/bitgen"
chmod 755 "$PREFIX/bin/bitgen"
cp -R share/boards.json share/boards "$PREFIX/share/"
printf '%s\n' "$(date +%Y.%m.%d)" > "$PREFIX/share/VERSION"

say "Сборка завершена"
"$PREFIX/bin/bitgen" --version
echo "prefix: $PREFIX"
echo "проверка: $PREFIX/bin/bitgen <design.vhd> -o out.bit"
