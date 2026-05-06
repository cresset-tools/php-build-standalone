#!/usr/bin/env bash
set -euo pipefail

: "${PBS_SRC_LIBCURL:?}"
: "${PBS_VER_LIBCURL:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_OPENSSL:?libcurl needs openssl for TLS}"
: "${PBS_DEP_ZLIB:?libcurl needs zlib for compression}"
: "${PBS_DEP_NGHTTP2:?libcurl needs nghttp2 for HTTP/2}"

src_dir="$PBS_SOURCES/curl-${PBS_VER_LIBCURL}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBCURL" -C "$PBS_SOURCES"
cd "$src_dir"

# DYLD_LIBRARY_PATH is the Mach-O equivalent of LD_LIBRARY_PATH used by
# curl's configure to run a sanity-check binary.
DYLD_LIBRARY_PATH="${PBS_DEPS_LDPATH:-}" \
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --with-openssl="$PBS_DEP_OPENSSL" \
  --with-nghttp2="$PBS_DEP_NGHTTP2" \
  --with-zlib="$PBS_DEP_ZLIB" \
  --without-libpsl \
  --without-libidn2 \
  --without-librtmp \
  --without-libssh2 \
  --without-brotli \
  --without-zstd \
  --without-libgsasl \
  --without-ngtcp2 \
  --without-quiche \
  --disable-ldap \
  --disable-ldaps \
  --disable-rtsp \
  --without-ca-bundle \
  --without-ca-path \
  --with-ca-fallback

make -j"$(getconf _NPROCESSORS_ONLN)" -C lib
make -j"$(getconf _NPROCESSORS_ONLN)" -C include
make -C lib install
make -C include install
make install-pkgconfigDATA 2>/dev/null || \
  make -C . install-data-am 2>/dev/null || \
  cp libcurl.pc "$PBS_DEPS/lib/pkgconfig/" 2>/dev/null || true

rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libcurl.dylib"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
echo "--- libcurl LC_LOAD_DYLIB audit ---"
otool -L "$lib" || true
echo "libcurl OK"
