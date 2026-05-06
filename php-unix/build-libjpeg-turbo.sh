#!/usr/bin/env bash
# Build libjpeg-turbo as a shared library into ${PBS_DEPS}.
# PHP's gd extension links against libjpeg for JPEG decode/encode.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh). No deps.
#
# libjpeg-turbo 3.x switched from autotools to CMake, so this script
# follows the cmake out-of-tree pattern rather than the ./configure
# pattern used by libsodium/sqlite.

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

# CMake flags rationale:
#   ENABLE_STATIC=OFF / ENABLE_SHARED=ON — shared-only, matches the
#       rest of the bundled deps.
#   WITH_TURBOJPEG=OFF — drop libturbojpeg.so (the alternate TurboJPEG
#       API) and the tjbench test binary. PHP's gd uses only the
#       traditional libjpeg API, and tjbench bakes the build directory
#       into its RPATH which finalize.sh would then have to rewrite.
#   WITH_SIMD=OFF — SIMD acceleration on x86_64 needs NASM (or yasm)
#       at build time; the PBS toolchain doesn't include either.
#       Trading some encode/decode speed for a smaller toolchain
#       surface; can be flipped on later by adding nasm to extraInputs.
#   CMAKE_INSTALL_LIBDIR=$PBS_DEPS/lib — force flat lib/, otherwise
#       cmake's GNUInstallDirs picks lib64/ on x86_64 which doesn't
#       match where the PHP build looks.
#   CMAKE_BUILD_TYPE=Release — without this, cmake defaults to an
#       empty build type which means no -O flag at all (CFLAGS from
#       setup-env.sh has -O2, but cmake may strip it).
#   CMAKE_OSX_DEPLOYMENT_TARGET — only meaningful on Darwin; harmless
#       on Linux where MACOSX_DEPLOYMENT_TARGET is unset and the var
#       expands to empty.
mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR="$PBS_DEPS/lib" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
  -DENABLE_STATIC=OFF \
  -DENABLE_SHARED=ON \
  -DWITH_TURBOJPEG=OFF \
  -DWITH_SIMD=OFF \
  ..

make -j"$PBS_NPROC"
make install

# Drop the CLI tools (cjpeg, djpeg, jpegtran, rdjpgcom, wrjpgcom). They
# embed the cmake build directory in their RPATH and PHP doesn't need
# any of them. Easier to delete than to teach finalize.sh about them.
rm -rf "$PBS_DEPS/bin"

# libjpeg-turbo also installs cmake config files (lib/cmake/libjpeg-turbo/)
# that hardcode the build-time /nix/store prefix. PHP and PECL extensions
# use pkg-config (the .pc file we keep) to discover libjpeg, so the cmake
# files are dead weight + a /nix/store-leak source. Drop them.
rm -rf "$PBS_DEPS/lib/cmake"

lib="$PBS_DEPS/lib/libjpeg.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libjpeg-turbo
echo "libjpeg-turbo OK"
