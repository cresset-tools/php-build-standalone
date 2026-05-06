#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_LIBZIP:?}"
: "${PBS_VER_LIBZIP:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?}"
: "${PBS_DEP_BZIP2:?}"
: "${PBS_DEP_OPENSSL:?}"

src_dir="$PBS_SOURCES/libzip-${PBS_VER_LIBZIP}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBZIP" -C "$PBS_SOURCES"
cd "$src_dir"

mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR="$PBS_DEPS/lib" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TOOLS=OFF \
  -DBUILD_REGRESS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_DOC=OFF \
  -DENABLE_BZIP2=ON \
  -DENABLE_OPENSSL=ON \
  -DENABLE_LZMA=OFF \
  -DENABLE_ZSTD=OFF \
  -DZLIB_ROOT="$PBS_DEP_ZLIB" \
  -DBZIP2_ROOT="$PBS_DEP_BZIP2" \
  -DOPENSSL_ROOT_DIR="$PBS_DEP_OPENSSL" \
  ..

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/lib/cmake"

lib="$PBS_DEPS/lib/libzip.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libzip LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libzip OK"
