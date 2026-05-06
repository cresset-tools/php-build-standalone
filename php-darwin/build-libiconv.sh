#!/usr/bin/env bash
# Build GNU libiconv as a Mach-O dylib into ${PBS_DEPS}.
# See sources.nix's libiconv entry for the why.

set -euo pipefail

: "${PBS_SRC_LIBICONV:?}"
: "${PBS_VER_LIBICONV:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/libiconv-${PBS_VER_LIBICONV}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBICONV" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$(getconf _NPROCESSORS_ONLN)"
make install

# libiconv installs an iconv binary; PHP doesn't need it.
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/share"

lib="$PBS_DEPS/lib/libiconv.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libiconv LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libiconv OK"
