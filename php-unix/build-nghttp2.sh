#!/usr/bin/env bash
# Build nghttp2 as a shared library into ${PBS_DEPS}.
# libcurl links against libnghttp2 to provide HTTP/2 support, which PHP's
# curl extension surfaces to userland.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh). No other
# deps — we only build the C library, not the C++ apps.

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

# --enable-lib-only skips the nghttp / nghttpd / h2load C++ apps, which
# would otherwise pull in libxml2, jemalloc, jansson, libev, libevent,
# etc. as deps. We only need libnghttp2 for libcurl.
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --enable-lib-only

make -j"$PBS_NPROC"
make install

rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libnghttp2.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" nghttp2
echo "nghttp2 OK"
