#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_LIBWEBP:?}"
: "${PBS_VER_LIBWEBP:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/libwebp-${PBS_VER_LIBWEBP}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBWEBP" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --disable-png \
  --disable-jpeg \
  --disable-tiff \
  --disable-gif \
  --disable-wic

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/share"

lib="$PBS_DEPS/lib/libwebp.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libwebp LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libwebp OK"
