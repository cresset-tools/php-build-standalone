#!/usr/bin/env bash
# Build liblz4 as a shared library into ${PBS_DEPS}.
#
# The redis PECL extension (--enable-redis-lz4 --with-liblz4) finds liblz4
# through pkg-config, so liblz4.pc has to land in $PBS_DEPS/lib/pkgconfig
# — see php/build-redis.sh.
#
# Only lib/ is built: the lz4 CLI never ships. BUILD_STATIC=no drops
# liblz4.a from both the build and `make install`. CFLAGS/LDFLAGS come
# from setup-env via the environment rather than the make command line —
# lib/Makefile appends its own flags with `+=`.

set -euo pipefail

: "${PBS_SRC_LZ4:?}"
: "${PBS_VER_LZ4:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/lz4-${PBS_VER_LZ4}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LZ4" -C "$PBS_SOURCES"
cd "$src_dir/lib"

make -j"$NIX_BUILD_CORES" BUILD_STATIC=no PREFIX="$PBS_DEPS" lib-release
make BUILD_STATIC=no PREFIX="$PBS_DEPS" LIBDIR="$PBS_DEPS/lib" install

lib="$PBS_DEPS/lib/liblz4.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
[ -e "$PBS_DEPS/lib/pkgconfig/liblz4.pc" ] || {
  echo "FATAL: liblz4.pc not produced — the redis extension resolves liblz4 via pkg-config" >&2
  exit 1
}
pbs_audit_lib "$lib" liblz4
echo "lz4 OK"
