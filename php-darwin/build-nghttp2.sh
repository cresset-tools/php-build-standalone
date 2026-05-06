#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_NGHTTP2:?}"
: "${PBS_VER_NGHTTP2:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/nghttp2-${PBS_VER_NGHTTP2}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_NGHTTP2" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --enable-lib-only

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libnghttp2.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- nghttp2 LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "nghttp2 OK"
