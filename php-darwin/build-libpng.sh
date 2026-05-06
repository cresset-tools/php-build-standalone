#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_LIBPNG:?}"
: "${PBS_VER_LIBPNG:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?libpng needs zlib}"

src_dir="$PBS_SOURCES/libpng-${PBS_VER_LIBPNG}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBPNG" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --with-zlib-prefix="$PBS_DEP_ZLIB" \
  --disable-static \
  --enable-shared

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libpng16.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libpng LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libpng OK"
