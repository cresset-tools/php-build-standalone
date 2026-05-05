#!/usr/bin/env bash
# Build zlib as a shared library into ${PBS_DEPS}. zlib's configure is
# hand-rolled (not autoconf) but it does honor CFLAGS/LDFLAGS/CC.
#
# Inherits CC, CFLAGS, LDFLAGS, AR/RANLIB and PBS_* paths from build-deps.sh.

set -euo pipefail

: "${PBS_SRC_ZLIB:?}"
: "${PBS_VER_ZLIB:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/zlib-${PBS_VER_ZLIB}"

# Fresh extract every time; deps builds aren't supposed to be incremental.
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ZLIB" -C "$PBS_SOURCES"

cd "$src_dir"

# zlib's configure ignores --build= and --host=; it auto-detects from CC.
# We only want the shared library — pass --static is harmless but produces
# a libz.a we don't need; explicitly disable below by removing it post-make.
./configure --prefix="$PBS_DEPS" --libdir="$PBS_DEPS/lib" --shared

make -j"$(nproc)"
make install

# zlib installs both libz.a and libz.so by default; we only ship shared.
rm -f "$PBS_DEPS/lib/libz.a"

# Sanity: the just-built libz.so must exist. RPATH is set in finalize.sh,
# not here, so we don't audit it at this stage.
lib="$PBS_DEPS/lib/libz.so"
if [ ! -L "$lib" ] && [ ! -f "$lib" ]; then
  echo "FATAL: $lib not produced" >&2
  exit 1
fi
echo "--- zlib NEEDED audit ---"
readelf -d "$(readlink -f "$lib")" | grep -E 'NEEDED' || true
echo "zlib OK"
