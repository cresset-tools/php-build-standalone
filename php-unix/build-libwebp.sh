#!/usr/bin/env bash
# Build libwebp as a shared library into ${PBS_DEPS}.
#
# PHP's gd extension links against libwebp.so to encode/decode the WebP
# image format. We ship a bundled copy so the tarball doesn't depend on
# the host's libwebp.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh. No other deps: we
# deliberately disable libwebp's libpng/libjpeg/libtiff/libgif bridges
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

# Configure flags rationale:
#   --disable-static / --enable-shared — shared-only, matches the rest
#                                        of the bundled deps.
#   --disable-png/jpeg/tiff/gif/wic    — drop libwebp's image-format
#                                        bridges. They're only used by
#                                        cwebp/dwebp CLI tools which we
#                                        strip below; PHP's gd doesn't
#                                        need them.
#   (libwebpmux / libwebpdemux are left enabled by default — gd uses
#   libwebpmux for some metadata operations.)
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

make -j"$(nproc)"
make install

# Drop CLI tools (cwebp, dwebp, etc.) and docs/man pages. The CLIs have
# the build-time /nix/store prefix baked in via libtool wrappers and
# PHP doesn't invoke them anyway. Same pattern as openssl/sqlite/
# oniguruma.
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/share"

# Sanity: shared lib must exist with a clean NEEDED list (no /nix/store
# leakage from the cc-wrapper-free toolchain).
lib="$PBS_DEPS/lib/libwebp.so"
real_lib="$(readlink -f "$lib")"
echo
echo "--- libwebp NEEDED audit ---"
needed=$(readelf -d "$real_lib" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: libwebp has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "libwebp OK"
