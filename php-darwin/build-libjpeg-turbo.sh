#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_LIBJPEG_TURBO:?}"
: "${PBS_VER_LIBJPEG_TURBO:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/libjpeg-turbo-${PBS_VER_LIBJPEG_TURBO}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBJPEG_TURBO" -C "$PBS_SOURCES"
cd "$src_dir"

mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR="$PBS_DEPS/lib" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DENABLE_STATIC=OFF \
  -DENABLE_SHARED=ON \
  -DWITH_TURBOJPEG=OFF \
  -DWITH_SIMD=OFF \
  ..

make -j"$(getconf _NPROCESSORS_ONLN)"
make install
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/lib/cmake"

lib="$PBS_DEPS/lib/libjpeg.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libjpeg-turbo LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libjpeg-turbo OK"
