#!/usr/bin/env bash
# Build bzip2 as a shared library into ${PBS_DEPS}.
#
# bzip2 has no configure; it ships two Makefiles — one for the static
# lib + CLI (which we use only for headers/manpages install plumbing),
# and one for the .so (Linux only — Darwin's dylib is hand-rolled).
# Neither honors LDFLAGS, only CC and CFLAGS.
#
# The shared-lib build mechanism diverges by platform; the right
# snippet to source is selected on the Nix side and passed in via
# $PBS_BZIP2_SHARED_BUILD (set by bzip2.nix). This script is OS-agnostic.

set -euo pipefail

: "${PBS_SRC_BZIP2:?}"
: "${PBS_VER_BZIP2:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_BZIP2_SHARED_BUILD:?set by bzip2.nix}"

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
# /lib64/ld-linux-x86-64.so.2 as the .interp (the path doesn't exist in
# the sandbox). The actual binary still works post-finalize on consumer
# hosts.
make -j"$NIX_BUILD_CORES" -f Makefile CC="$CC" CFLAGS="$CFLAGS" libbz2.a bzip2 bzip2recover
# `make install` also depends on `all` → would re-trigger test. Override
# with `install` calling the same prerequisite list we just satisfied.
make install PREFIX="$PBS_DEPS" -o test
rm -f "$PBS_DEPS/lib/libbz2.a"

# Second pass: build the shared library. Mechanism is platform-specific
# — Nix-selected snippet provides it.
source "$PBS_BZIP2_SHARED_BUILD"

# PHP doesn't need the bzip2/bunzip2 CLIs; drop them to keep the tarball lean.
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libbz2.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libbz2
echo "bzip2 OK"
