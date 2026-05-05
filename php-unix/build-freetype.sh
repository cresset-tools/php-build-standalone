#!/usr/bin/env bash
# Build FreeType as a shared library into ${PBS_DEPS}, with zlib + bzip2
# support for compressed font tables. Used by PHP's gd extension for
# TrueType text rendering (imagettftext, imagettfbbox, etc).
#
# Inherits CC, CFLAGS, LDFLAGS, plus PBS_DEP_ZLIB / PBS_DEP_BZIP2 pointing
# at the respective derivations' $out (auto-appended -I/-L by mkDep.nix).

set -euo pipefail

: "${PBS_SRC_FREETYPE:?}"
: "${PBS_VER_FREETYPE:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?freetype needs zlib}"
: "${PBS_DEP_BZIP2:?freetype needs bzip2}"

src_dir="$PBS_SOURCES/freetype-${PBS_VER_FREETYPE}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_FREETYPE" -C "$PBS_SOURCES"
cd "$src_dir"

# FreeType ships a top-level ./configure wrapper that delegates to
# builds/unix/configure under GNU make's recursive rules. Running from
# the top level is the supported entry point.
#
# Configure flags rationale:
#   --with-zlib=yes       — autodetected via PBS_DEP_ZLIB paths in
#                           CFLAGS/LDFLAGS (auto-appended by mkDep).
#   --with-bzip2=yes      — same, autodetected via PBS_DEP_BZIP2.
#   --with-png=no         — FreeType can use libpng for PNG-embedded color
#                           fonts (Apple/Google emoji); PHP's gd doesn't
#                           rely on that path. Skip to keep dep graph simple.
#   --with-harfbuzz=no    — circular dep: HarfBuzz uses FreeType, FreeType
#                           can use HarfBuzz for OpenType auto-hinting.
#                           Disable to break the cycle.
#   --with-brotli=no      — extra compression for WOFF2 web fonts; PHP
#                           server-side rendering doesn't need it.
#   --disable-static      — shared only.
#   --enable-shared       — explicit (defense in depth, libtool default).
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --with-zlib=yes \
  --with-bzip2=yes \
  --with-png=no \
  --with-harfbuzz=no \
  --with-brotli=no

make -j"$(nproc)"
make install

# Drop helper binaries (freetype-config etc): they bake in build-time
# absolute paths and we use the installed .pc file (freetype2.pc) instead.
rm -rf "$PBS_DEPS/bin"

# Sanity: shared lib must exist with a clean NEEDED list (no /nix/store
# leaks from the build sandbox into DT_NEEDED).
lib="$PBS_DEPS/lib/libfreetype.so"
real_lib="$(readlink -f "$lib")"
echo
echo "--- freetype NEEDED audit ---"
needed=$(readelf -d "$real_lib" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: freetype has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "freetype OK"
