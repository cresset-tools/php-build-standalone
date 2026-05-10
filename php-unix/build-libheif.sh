#!/usr/bin/env bash
# Build libheif as a shared library into ${PBS_DEPS}.
# ImageMagick links against libheif for HEIF/HEIC (.heic) read.
#
# Configuration: decode-only via libde265. Every encoder backend is
# explicitly OFF — auto-detection would happily wire up to system
# libs otherwise. We also disable the example binaries (heif-*)
# which bake the cmake build dir into their RPATH.

set -euo pipefail

: "${PBS_SRC_LIBHEIF:?}"
: "${PBS_VER_LIBHEIF:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_LIBDE265:?}"

src_dir="$PBS_SOURCES/libheif-${PBS_VER_LIBHEIF}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBHEIF" -C "$PBS_SOURCES"
cd "$src_dir"

mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR="$PBS_DEPS/lib" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DWITH_EXAMPLES=OFF \
  -DWITH_GDK_PIXBUF=OFF \
  -DWITH_LIBDE265=ON \
  -DWITH_X265=OFF \
  -DWITH_AOM_DECODER=OFF \
  -DWITH_AOM_ENCODER=OFF \
  -DWITH_DAV1D=OFF \
  -DWITH_KVAZAAR=OFF \
  -DWITH_SvtEnc=OFF \
  -DWITH_RAV1E=OFF \
  -DWITH_FFMPEG_DECODER=OFF \
  -DENABLE_PLUGIN_LOADING=OFF \
  -DLIBDE265_INCLUDE_DIR="$PBS_DEP_LIBDE265/include" \
  -DLIBDE265_LIBRARY="$PBS_DEP_LIBDE265/lib/libde265.${PBS_LIB_EXT}" \
  ..

make -j"$NIX_BUILD_CORES"
make install

rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/lib/cmake"
rm -rf "$PBS_DEPS/share"

lib="$PBS_DEPS/lib/libheif.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libheif
echo "libheif OK"
