#!/usr/bin/env bash
# Build zlib as a shared library into ${PBS_DEPS} on macOS.
# Mirrors php-unix/build-zlib.sh but writes libz.dylib (not libz.so) and
# uses Darwin-portable invocations (no nproc, no readelf).

set -euo pipefail

: "${PBS_SRC_ZLIB:?}"
: "${PBS_VER_ZLIB:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/zlib-${PBS_VER_ZLIB}"

rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ZLIB" -C "$PBS_SOURCES"

cd "$src_dir"

# zlib's configure auto-detects Darwin from `uname` and emits a
# libz.<ver>.dylib + symlinks instead of the .so chain. CC/CFLAGS/LDFLAGS
# are honored. --shared keeps shared-only.
./configure --prefix="$PBS_DEPS" --libdir="$PBS_DEPS/lib" --shared

# Cross-platform job count: getconf works on both Linux and Darwin.
make -j"$(getconf _NPROCESSORS_ONLN)"
make install

# zlib installs both libz.a and libz.<ver>.dylib by default; we only ship shared.
rm -f "$PBS_DEPS/lib/libz.a"

# Sanity: the just-built libz.dylib must exist. install_name is finalized
# in finalize.sh; here we just verify the artifact and dump LC_LOAD_DYLIB
# entries for inspection.
lib="$PBS_DEPS/lib/libz.dylib"
if [ ! -L "$lib" ] && [ ! -f "$lib" ]; then
  echo "FATAL: $lib not produced" >&2
  exit 1
fi
echo "--- zlib LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "zlib OK"
