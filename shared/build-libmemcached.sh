#!/usr/bin/env bash
# Build libmemcached-awesome as shared libraries into ${PBS_DEPS}.
#
# The `memcached` PECL extension locates it via pkg-config
# (libmemcached.pc), so that file has to land in $PBS_DEPS/lib/pkgconfig —
# see php/build-memcached.sh.

set -euo pipefail

: "${PBS_SRC_LIBMEMCACHED:?}"
: "${PBS_VER_LIBMEMCACHED:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/libmemcached-${PBS_VER_LIBMEMCACHED}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBMEMCACHED" -C "$PBS_SOURCES"
cd "$src_dir"

# Linux: -static-libstdc++ -static-libgcc (see shared/libmemcached.nix).
export LDFLAGS="${LDFLAGS:-} ${PBS_LIBMEMCACHED_EXTRA_LDFLAGS:-}"

# CMake flags rationale:
#   CMAKE_INSTALL_LIBDIR=lib — RELATIVE, unlike build-libuv.sh.
#       support/libmemcached.pc.in spells its Libs line as
#       -L@CMAKE_INSTALL_PREFIX@/@CMAKE_INSTALL_LIBDIR@, so an absolute
#       libdir would produce -L$PBS_DEPS/$PBS_DEPS/lib and the extension's
#       link probe would miss the library.
#   BUILD_TESTING=OFF — the suite needs a memcached server binary.
#   BUILD_DOCS=OFF — needs sphinx.
#   ENABLE_SASL=OFF — see shared/libmemcached.nix.
#   ENABLE_OPENSSL_CRYPTO=OFF — keep the bundled AES; no libcrypto edge.
#   ENABLE_BACKTRACE=OFF — defaults ON and probes for <execinfo.h>, which
#       glibc has and musl does not; off keeps every target on the same
#       code path, and the backtraces only print on internal assertion
#       failures anyway.
#   ENABLE_DTRACE=OFF — explicit; it would pick up a host dtrace on Darwin.
#   ENABLE_MEMASLAP=OFF — the load generator; nothing ships it.
#   The mem* client binaries (memcat, memcp, …) are built unconditionally
#   from a hardcoded CLIENTS list and deleted after install.
mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DBUILD_DOCS=OFF \
  -DENABLE_SASL=OFF \
  -DENABLE_OPENSSL_CRYPTO=OFF \
  -DENABLE_BACKTRACE=OFF \
  -DENABLE_DTRACE=OFF \
  -DENABLE_MEMASLAP=OFF \
  ..

make -j"$NIX_BUILD_CORES"
make install

# Client binaries, the cmake package config, and share/ (aclocal macro,
# example.cnf, docs). None of it ships.
rm -rf "$PBS_DEPS/bin" "$PBS_DEPS/lib/cmake" "$PBS_DEPS/share"

[ -e "$PBS_DEPS/lib/pkgconfig/libmemcached.pc" ] || {
  echo "FATAL: libmemcached.pc not produced — the memcached extension resolves libmemcached via pkg-config" >&2
  exit 1
}
for libname in libmemcached libmemcachedutil libhashkit; do
  lib="$PBS_DEPS/lib/${libname}.${PBS_LIB_EXT}"
  [ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
  pbs_audit_lib "$lib" "$libname"
done
echo "libmemcached OK"
