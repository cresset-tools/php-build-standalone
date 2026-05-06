#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_LIBEDIT:?}"
: "${PBS_VER_LIBEDIT:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_NCURSES:?libedit needs ncurses}"

src_dir="$PBS_SOURCES/libedit-${PBS_VER_LIBEDIT}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBEDIT" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/share/man"

lib="$PBS_DEPS/lib/libedit.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libedit LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libedit OK"
