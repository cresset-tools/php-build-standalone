#!/usr/bin/env bash
# Build FreeType as a shared library into ${PBS_DEPS}, with zlib + bzip2
# support for compressed font tables. Used by PHP's gd extension for
# TrueType text rendering (imagettftext, imagettfbbox, etc).
#
# Inherits CC, CFLAGS, LDFLAGS, plus PBS_DEP_ZLIB / PBS_DEP_BZIP2 pointing
# at the respective derivations' $out (auto-appended -I/-L by mkDep).

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

# Configure flags rationale:
#   --with-zlib=yes       — autodetected via PBS_DEP_ZLIB paths in
#                           CFLAGS/LDFLAGS (auto-appended by mkDep).
#   --with-bzip2=yes      — same, autodetected via PBS_DEP_BZIP2.
#   --with-png=no         — FreeType can use libpng for PNG-embedded color
#                           fonts (Apple/Google emoji); PHP's gd doesn't
#                           rely on that path.
#   --with-harfbuzz=no    — circular dep: HarfBuzz uses FreeType,
#                           FreeType can use HarfBuzz for OpenType
#                           auto-hinting. Disable to break the cycle.
#   --with-brotli=no      — extra compression for WOFF2 web fonts; PHP
#                           server-side rendering doesn't need it.
#   --disable-static      — shared only.
#   --enable-shared       — explicit (defense in depth).
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

make -j"$PBS_NPROC"
make install

# Drop helper binaries (freetype-config etc): they bake in build-time
# absolute paths and we use the installed .pc file (freetype2.pc) instead.
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libfreetype.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" freetype
echo "freetype OK"
