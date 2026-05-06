#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_SQLITE:?}"
: "${PBS_VER_SQLITE:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

rm -rf "$PBS_SOURCES"/sqlite-autoconf-*
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_SQLITE" -C "$PBS_SOURCES"
src_dir=$(echo "$PBS_SOURCES"/sqlite-autoconf-*)
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --disable-readline \
  --disable-tcl \
  --disable-editline

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libsqlite3.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- sqlite LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "sqlite OK"
