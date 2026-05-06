#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_LIBSODIUM:?}"
: "${PBS_VER_LIBSODIUM:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/libsodium-${PBS_VER_LIBSODIUM}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBSODIUM" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$(getconf _NPROCESSORS_ONLN)"
make install

lib="$PBS_DEPS/lib/libsodium.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libsodium LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libsodium OK"
