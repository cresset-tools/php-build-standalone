#!/usr/bin/env bash
# Build zlib as a shared library into ${PBS_DEPS}. zlib's configure is
# hand-rolled (not autoconf) but it does honor CFLAGS/LDFLAGS/CC, and
# auto-detects ELF vs Mach-O output from $CC + uname.
#
# Inherits CC, CFLAGS, LDFLAGS, AR/RANLIB and PBS_* paths from the
# platform setup-env (setup-env-linux.sh / setup-env-darwin.sh).
# NIX_BUILD_CORES comes from the Nix sandbox itself, not setup-env.

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

make -j"$NIX_BUILD_CORES"
make install

# zlib installs both libz.a and libz.so/dylib by default; we only ship shared.
rm -f "$PBS_DEPS/lib/libz.a"

# Sanity: the just-built libz must exist. RPATH/install_name is set in
# finalize.sh, not here.
lib="$PBS_DEPS/lib/libz.${PBS_LIB_EXT}"
if [ ! -L "$lib" ] && [ ! -f "$lib" ]; then
  echo "FATAL: $lib not produced" >&2
  exit 1
fi
pbs_audit_lib "$lib" zlib
echo "zlib OK"
