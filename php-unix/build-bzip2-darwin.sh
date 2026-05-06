#!/usr/bin/env bash
# Build bzip2 as a Mach-O dylib into ${PBS_DEPS}. Upstream bzip2 ships
# `Makefile-libbz2_so` which only knows how to produce a Linux ELF .so;
# on Darwin we drive the dylib link by hand with -dynamiclib.

set -euo pipefail

: "${PBS_SRC_BZIP2:?}"
: "${PBS_VER_BZIP2:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/bzip2-${PBS_VER_BZIP2}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_BZIP2" -C "$PBS_SOURCES"
cd "$src_dir"

# Static + headers + manpages via the regular Makefile (skipping `test`,
# which would try to exec the just-built bzip2 — fine on Darwin but we
# don't need the artifact). We drop libbz2.a immediately afterwards.
make -j"$(getconf _NPROCESSORS_ONLN)" -f Makefile CC="$CC" CFLAGS="$CFLAGS" libbz2.a bzip2 bzip2recover
make install PREFIX="$PBS_DEPS" -o test
rm -f "$PBS_DEPS/lib/libbz2.a"

# Compile PIC objects then link a dylib. The objects from the static
# build are not -fPIC by default in bzip2's Makefile, so rebuild them.
src_files="blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c"
for s in $src_files; do
  $CC -fPIC -O2 -c "$s"
done

# Versioned dylib name: libbz2.<major>.<minor>.<patch>.dylib
ver="${PBS_VER_BZIP2}"
major="${ver%%.*}"
rest="${ver#*.}"
minor="${rest%%.*}"

dylib="libbz2.${ver}.dylib"
# Install name is the absolute build-time path so consumers linking
# against this dylib pick up an LC_LOAD_DYLIB pointing at /nix/store/...,
# which dyld can resolve at build time without needing DYLD_LIBRARY_PATH
# (macOS strips DYLD_* across some exec chains). finalize-darwin rewrites
# the absolute path to @rpath/<basename> at tarball time.
$CC -dynamiclib -Wl,-install_name,"$PBS_DEPS/lib/$dylib" \
    -compatibility_version "${major}.${minor}" \
    -current_version "$ver" \
    -o "$dylib" \
    blocksort.o huffman.o crctable.o randtable.o compress.o decompress.o bzlib.o

cp "$dylib" "$PBS_DEPS/lib/"
ln -sf "$dylib" "$PBS_DEPS/lib/libbz2.${major}.${minor}.dylib"
ln -sf "$dylib" "$PBS_DEPS/lib/libbz2.${major}.dylib"
ln -sf "$dylib" "$PBS_DEPS/lib/libbz2.dylib"

rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libbz2.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- bzip2 LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "bzip2 OK"
