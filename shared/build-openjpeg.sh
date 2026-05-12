#!/usr/bin/env bash
# Build openjpeg as a shared library into ${PBS_DEPS}.
# ImageMagick links against libopenjp2 for JPEG 2000 read/write.
#
# openjpeg uses cmake. We build the library only (BUILD_CODEC=OFF)
# because IM doesn't need opj_compress / opj_decompress / opj_dump
# CLIs and they bake the cmake build dir into their RPATH otherwise.
#
# Inputs: zlib (mandatory for embedded codestream compression), libpng
# + libtiff + lcms2 (only used by the codec CLIs we disable, but
# cmake's Find* modules probe regardless and we want them resolving
# to bundled deps if anything).

set -euo pipefail

: "${PBS_SRC_OPENJPEG:?}"
: "${PBS_VER_OPENJPEG:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?}"

src_dir="$PBS_SOURCES/openjpeg-${PBS_VER_OPENJPEG}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_OPENJPEG" -C "$PBS_SOURCES"
cd "$src_dir"

mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR="$PBS_DEPS/lib" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC_LIBS=OFF \
  -DBUILD_CODEC=OFF \
  -DBUILD_DOC=OFF \
  -DBUILD_TESTING=OFF \
  -DZLIB_ROOT="$PBS_DEP_ZLIB" \
  ..

make -j"$NIX_BUILD_CORES"
make install

rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/lib/cmake"
rm -rf "$PBS_DEPS/share"

lib="$PBS_DEPS/lib/libopenjp2.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libopenjp2
echo "openjpeg OK"
