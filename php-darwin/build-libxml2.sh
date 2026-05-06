#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_LIBXML2:?}"
: "${PBS_VER_LIBXML2:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?libxml2 needs zlib}"

src_dir="$PBS_SOURCES/libxml2-${PBS_VER_LIBXML2}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBXML2" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --without-python \
  --without-lzma \
  --without-iconv \
  --with-zlib="$PBS_DEP_ZLIB" \
  --disable-static \
  --enable-shared

make -j"$(getconf _NPROCESSORS_ONLN)" libxml2.la
make install-libLTLIBRARIES install-pkgconfigDATA
make -C include install

lib="$PBS_DEPS/lib/libxml2.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libxml2 LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libxml2 OK"
