#!/usr/bin/env bash
# Build libzstd as a shared library into ${PBS_DEPS}.
#
# The redis PECL extension (--enable-redis-zstd) finds libzstd through
# pkg-config, so libzstd.pc has to land in $PBS_DEPS/lib/pkgconfig — see
# php/build-redis.sh.
#
# Only lib/ is built: the zstd CLI and its programs/ tree never ship.
# CFLAGS/LDFLAGS come from setup-env via the environment rather than the
# make command line — lib/Makefile appends its own flags with `+=`, which
# a command-line assignment would silently override.

set -euo pipefail

: "${PBS_SRC_ZSTD:?}"
: "${PBS_VER_ZSTD:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/zstd-${PBS_VER_ZSTD}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ZSTD" -C "$PBS_SOURCES"
cd "$src_dir/lib"

# `libzstd` is the shared library alone (multithreaded, the upstream
# default); `install-shared install-includes install-pc` skips the static
# archive that plain `install` would also put in place.
make -j"$NIX_BUILD_CORES" PREFIX="$PBS_DEPS" libzstd
make PREFIX="$PBS_DEPS" LIBDIR="$PBS_DEPS/lib" \
  install-shared install-includes install-pc

lib="$PBS_DEPS/lib/libzstd.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
[ -e "$PBS_DEPS/lib/pkgconfig/libzstd.pc" ] || {
  echo "FATAL: libzstd.pc not produced — the redis extension resolves libzstd via pkg-config" >&2
  exit 1
}
pbs_audit_lib "$lib" libzstd
echo "zstd OK"
