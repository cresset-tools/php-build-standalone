#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_FREETYPE:?}"
: "${PBS_VER_FREETYPE:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?freetype needs zlib}"
: "${PBS_DEP_BZIP2:?freetype needs bzip2}"

src_dir="$PBS_SOURCES/freetype-${PBS_VER_FREETYPE}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_FREETYPE" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --with-zlib=yes \
  --with-bzip2=yes \
  --with-png=no \
  --with-harfbuzz=no \
  --with-brotli=no

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libfreetype.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- freetype LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "freetype OK"
