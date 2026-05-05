#!/usr/bin/env bash
# Build nghttp2 as a shared library into ${PBS_DEPS}.
# libcurl links against libnghttp2.so to provide HTTP/2 support, which PHP's
# curl extension surfaces to userland.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh. No other deps — we only
# build the C library, not the C++ apps.

set -euo pipefail

: "${PBS_SRC_NGHTTP2:?}"
: "${PBS_VER_NGHTTP2:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/nghttp2-${PBS_VER_NGHTTP2}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_NGHTTP2" -C "$PBS_SOURCES"
cd "$src_dir"

# Configure flags rationale:
#   --disable-static / --enable-shared — shared-only, matches the rest of
#                                        the bundled deps.
#   --enable-lib-only                  — skip the nghttp / nghttpd / h2load
#                                        C++ apps, which would otherwise pull
#                                        in libxml2, jemalloc, jansson,
#                                        libev, libevent, etc. as deps. We
#                                        only need libnghttp2 for libcurl.
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --enable-lib-only

make -j"$(nproc)"
make install

# --enable-lib-only should keep bin/ empty, but defensively drop anything
# that landed there (some configurations install helper scripts).
rm -rf "$PBS_DEPS/bin"

# Sanity: shared lib must exist with a clean NEEDED list (no /nix/store
# leakage).
lib="$PBS_DEPS/lib/libnghttp2.so"
real_lib="$(readlink -f "$lib")"
echo
echo "--- nghttp2 NEEDED audit ---"
needed=$(readelf -d "$real_lib" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: libnghttp2 has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "nghttp2 OK"
