#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_ONIGURUMA:?}"
: "${PBS_VER_ONIGURUMA:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

# Upstream tarball extracts to onig-<ver>/ rather than oniguruma-<ver>/;
# match the Linux build script.
src_dir="$PBS_SOURCES/onig-${PBS_VER_ONIGURUMA}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ONIGURUMA" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libonig.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- oniguruma LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "oniguruma OK"
