#!/usr/bin/env bash
# Build bzip2 as a shared library into ${PBS_DEPS}. bzip2 has no configure;
# it ships two Makefiles — one for the static lib + CLI (which we use only
# for headers/manpages install plumbing), and one for the .so. Neither
# honors LDFLAGS, only CC and CFLAGS.
#
# Inherits CC, CFLAGS, LDFLAGS, AR/RANLIB and PBS_* paths from setup-env.sh.

set -euo pipefail

: "${PBS_SRC_BZIP2:?}"
: "${PBS_VER_BZIP2:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/bzip2-${PBS_VER_BZIP2}"

# Fresh extract every time; deps builds aren't supposed to be incremental.
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_BZIP2" -C "$PBS_SOURCES"

cd "$src_dir"

# First pass: build with the regular Makefile to populate headers + manpages
# via its `install` target. We then drop libbz2.a since we ship shared only.
make -j"$(nproc)" -f Makefile CC="$CC" CFLAGS="$CFLAGS"
make install PREFIX="$PBS_DEPS"
rm -f "$PBS_DEPS/lib/libbz2.a"

# Second pass: build the shared library. Makefile-libbz2_so produces
# libbz2.so.1.0.8 but has no install target.
make -f Makefile-libbz2_so CC="$CC" CFLAGS="$CFLAGS"

cp libbz2.so.1.0.8 "$PBS_DEPS/lib/"
ln -sf libbz2.so.1.0.8 "$PBS_DEPS/lib/libbz2.so.1.0"
ln -sf libbz2.so.1.0.8 "$PBS_DEPS/lib/libbz2.so.1"
ln -sf libbz2.so.1.0.8 "$PBS_DEPS/lib/libbz2.so"

# PHP doesn't need the bzip2/bunzip2 CLIs; drop them to keep the tarball lean.
rm -rf "$PBS_DEPS/bin"

# Sanity: the just-built libbz2.so must exist. RPATH is set in finalize.sh,
# not here, so we don't audit it at this stage.
lib="$PBS_DEPS/lib/libbz2.so"
if [ ! -L "$lib" ] && [ ! -f "$lib" ]; then
  echo "FATAL: $lib not produced" >&2
  exit 1
fi
echo "--- bzip2 NEEDED audit ---"
readelf -d "$(readlink -f "$lib")" | grep -E 'NEEDED' || true
echo "bzip2 OK"
