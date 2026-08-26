#!/usr/bin/env bash
# Build libuv as a shared library into ${PBS_DEPS}.
#
# The `uv` PECL extension (ReactPHP's ExtUvLoop) links against it and
# locates it via pkg-config, so libuv.pc has to land in
# $PBS_DEPS/lib/pkgconfig — see php/build-uv.sh.
#
# cmake, not autotools: the dist tarball carries CMakeLists.txt and
# autogen.sh but no pre-generated `configure`.

set -euo pipefail

: "${PBS_SRC_LIBUV:?}"
: "${PBS_VER_LIBUV:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

# dist.libuv.org names the extract dir with a leading `v` on the version
# (libuv-v1.52.1/), unlike our internal libuv-<version> key.
src_dir="$PBS_SOURCES/libuv-v${PBS_VER_LIBUV}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBUV" -C "$PBS_SOURCES"
cd "$src_dir"

# CMake flags rationale:
#   LIBUV_BUILD_SHARED=ON — shared-only consumers; also the switch that
#       gates installing libuv.pc (the static build installs only
#       libuv-static.pc, which the uv extension's pkg-config probe for
#       `libuv` would not find).
#   BUILD_TESTING=OFF — skips the test + benchmark runners.
#   ENABLE_CLANG_TIDY=OFF — REQUIRED. It defaults to ON upstream, and
#       when clang-tidy isn't on PATH the CMakeLists still sets
#       CMAKE_C_CLANG_TIDY to the bare string "clang-tidy", so every
#       compile shells out to a binary that doesn't exist and the build
#       dies. Our toolchain ships wrapped clang without clang-tidy.
#   CMAKE_INSTALL_LIBDIR=$PBS_DEPS/lib — force flat lib/, matching
#       build-libzip.sh (cmake would otherwise pick lib64 on some hosts).
#   CMAKE_OSX_DEPLOYMENT_TARGET — only meaningful on Darwin.
mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR="$PBS_DEPS/lib" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
  -DLIBUV_BUILD_SHARED=ON \
  -DBUILD_TESTING=OFF \
  -DENABLE_CLANG_TIDY=OFF \
  ..

make -j"$NIX_BUILD_CORES"
make install

# libuv installs the static archive and its .pc unconditionally (they sit
# outside the LIBUV_BUILD_SHARED guard), plus a cmake package config and
# LICENSE copies under share/doc. None of it ships.
rm -rf "$PBS_DEPS/lib/cmake" "$PBS_DEPS/share"
# The `uv_a` cmake target installs under the plain `libuv.a` name, not
# `libuv_a.a`.
rm -f "$PBS_DEPS/lib/libuv.a" "$PBS_DEPS/lib/pkgconfig/libuv-static.pc"

lib="$PBS_DEPS/lib/libuv.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
[ -e "$PBS_DEPS/lib/pkgconfig/libuv.pc" ] || {
  echo "FATAL: libuv.pc not produced — the uv extension resolves libuv via pkg-config" >&2
  exit 1
}
pbs_audit_lib "$lib" libuv
echo "libuv OK"
