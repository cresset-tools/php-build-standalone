#!/usr/bin/env bash
# Build libpng as a shared library into ${PBS_DEPS}, against the bundled zlib.
#
# Inherits CC, CFLAGS, LDFLAGS, plus PBS_DEP_ZLIB pointing at the zlib
# derivation's $out (auto-appended -I/-L by mkDep).
#
# Output of interest: $PBS_DEPS/lib/libpng16.{so,dylib}* (versioned
# soname; the unversioned libpng.so/.dylib is just a symlink).

set -euo pipefail

: "${PBS_SRC_LIBPNG:?}"
: "${PBS_VER_LIBPNG:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?libpng needs zlib}"

src_dir="$PBS_SOURCES/libpng-${PBS_VER_LIBPNG}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBPNG" -C "$PBS_SOURCES"
cd "$src_dir"

# Configure flags rationale:
#   --with-zlib-prefix=$DEP — libpng's configure looks for zlib.h /
#                             -lz under this prefix. mkDep already
#                             appended -I/-L for the zlib dep, but
#                             libpng's configure also runs an explicit
#                             link-test using this prefix var, so set
#                             it to be safe.
#   --disable-static        — shared only.
#   --enable-shared         — explicit defense in depth.
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --with-zlib-prefix="$PBS_DEP_ZLIB" \
  --disable-static \
  --enable-shared

make -j"$PBS_NPROC"
make install

# Drop the helper executables: libpng-config and png-fix-itxt embed the
# build-time $out path as text, which would normally fail the /nix/store
# text-file audit applied by tree finalization. PHP's gd build doesn't
# need these helpers (it uses pkg-config + headers).
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libpng16.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libpng
echo "libpng OK"
