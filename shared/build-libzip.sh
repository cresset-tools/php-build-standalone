#!/usr/bin/env bash
# Build libzip as a shared library into ${PBS_DEPS}.
# PHP's zip extension links against libzip for ZIP archive read/write
# support.
#
# libzip uses cmake. We enable bzip2 + openssl (AES-encrypted entries)
# but disable lzma/zstd because the PBS bundle doesn't carry xz or zstd.
#
# Inputs: zlib (mandatory), bzip2 (optional bz2-compressed entries),
# openssl (optional AES support). Tools/regress/examples/doc are off:
# PHP doesn't need the zipcmp/zipmerge/ziptool CLIs and they bake the
# cmake build dir into their RPATH otherwise.

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

# CMake flags rationale:
#   BUILD_SHARED_LIBS=ON — shared-only, matches the rest of the bundle.
#   BUILD_TOOLS/REGRESS/EXAMPLES/DOC=OFF — PHP only needs the library.
#   ENABLE_BZIP2/OPENSSL=ON — opt into bzip2-compressed and AES-encrypted
#       entry support, using our bundled deps.
#   ENABLE_LZMA/ZSTD=OFF — we don't ship xz or zstd in the bundle.
#   *_ROOT / OPENSSL_ROOT_DIR — point cmake's Find* modules at the
#       bundled-dep prefixes so it doesn't pick up system copies.
#   CMAKE_INSTALL_LIBDIR=$PBS_DEPS/lib — force flat lib/.
#   CMAKE_OSX_DEPLOYMENT_TARGET — only meaningful on Darwin.
mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR="$PBS_DEPS/lib" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
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

make -j"$NIX_BUILD_CORES"
make install

rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/lib/cmake"

lib="$PBS_DEPS/lib/libzip.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libzip
echo "libzip OK"
