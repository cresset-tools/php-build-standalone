#!/usr/bin/env bash
# Build libpng as a shared library into ${PBS_DEPS}, against the bundled zlib.
#
# Inherits CC, CFLAGS, LDFLAGS, plus PBS_DEP_ZLIB pointing at the zlib
# derivation's $out (auto-appended -I/-L by mkDep.nix).
#
# Output of interest: $PBS_DEPS/lib/libpng16.so* (versioned soname; the
# unversioned libpng.so is just a symlink installed alongside).

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
#                             -lz under this prefix. mkDep.nix already
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

make -j"$(nproc)"
make install

# Drop the helper executables: libpng-config and png-fix-itxt embed the
# build-time $out path as text, which would normally fail the /nix/store
# text-file audit applied by tree finalization. PHP's gd build doesn't
# need these helpers (it uses pkg-config + headers). Same pattern as
# openssl / sqlite / oniguruma in this tree.
rm -rf "$PBS_DEPS/bin"

# Sanity: shared lib must exist with a clean NEEDED list (no /nix/store
# leakage from the build-time toolchain).
lib="$PBS_DEPS/lib/libpng16.so"
real_lib="$(readlink -f "$lib")"
echo
echo "--- libpng NEEDED audit ---"
needed=$(readelf -d "$real_lib" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: libpng has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "libpng OK"
