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
# Skip the default `test` step — bzip2's Makefile runs the just-built CLI,
# which the Nix sandbox can't exec because our wrapper bakes in
# /lib64/ld-linux-x86-64.so.2 as the .interp (the path doesn't exist in the
# sandbox). The actual binary still works post-finalize on consumer hosts.
# Build only the targets we install — libbz2.a, bzip2, bzip2recover —
# and skip `all`'s implicit `test` dependency.
make -j"$(nproc)" -f Makefile CC="$CC" CFLAGS="$CFLAGS" libbz2.a bzip2 bzip2recover
# `make install` also depends on `all` → would re-trigger test. Override
# with `install` calling the same prerequisite list we just satisfied.
make install PREFIX="$PBS_DEPS" -o test
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
