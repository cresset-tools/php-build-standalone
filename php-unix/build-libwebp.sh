#!/usr/bin/env bash
# Build libwebp as a shared library into ${PBS_DEPS}.
#
# PHP's gd extension links against libwebp to encode/decode the WebP
# image format. We ship a bundled copy so the tarball doesn't depend on
# the host's libwebp.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh). No deps:
# we deliberately disable libwebp's libpng/libjpeg/libtiff/libgif bridges
# (used only by libwebp's own cwebp/dwebp CLIs to read/write source
# images). PHP's gd does its own format conversions and uses libwebp
# purely for raw WebP encode/decode, so dropping those bridges saves us
# pulling libpng/libjpeg into libwebp's link line.

set -euo pipefail

: "${PBS_SRC_LIBWEBP:?}"
: "${PBS_VER_LIBWEBP:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/libwebp-${PBS_VER_LIBWEBP}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBWEBP" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --disable-png \
  --disable-jpeg \
  --disable-tiff \
  --disable-gif \
  --disable-wic

make -j"$NIX_BUILD_CORES"
make install

# Drop CLI tools (cwebp, dwebp, etc.) and docs/man pages.
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/share"

lib="$PBS_DEPS/lib/libwebp.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libwebp
echo "libwebp OK"
