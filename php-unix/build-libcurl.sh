#!/usr/bin/env bash
# Build libcurl as a shared library into ${PBS_DEPS}.
#
# Inherits CC, CFLAGS, LDFLAGS, plus PBS_DEP_OPENSSL, PBS_DEP_ZLIB, and
# PBS_DEP_NGHTTP2 pointing at the respective dep derivations' $out
# (auto-appended -I/-L by mkDep). PHP's curl extension links against
# libcurl at runtime; we deliberately do not ship the curl CLI binary.

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

# Configure flags rationale:
#   --with-openssl=$DEP        — TLS backend; PHP's curl wraps OpenSSL-style
#                                APIs (CURLOPT_SSL_VERIFYPEER etc).
#   --with-nghttp2=$DEP        — HTTP/2 support against the bundled nghttp2.
#   --with-zlib=$DEP           — gzip/deflate Content-Encoding support.
#
#   --without-libpsl/libidn2/librtmp/libssh2/brotli/zstd/libgsasl/ngtcp2/quiche
#                              — drop optional features that would either
#                                pull in a system lib or extra bundled deps.
#                                PHP curl extension surface doesn't expose
#                                them in any common usage.
#   --disable-ldap/-ldaps/-rtsp — protocols PHP doesn't use.
#   --without-ca-bundle / --without-ca-path / --with-ca-fallback
#                              — don't bake a build-time CA path; let curl
#                                walk its built-in fallback list at runtime.
#                                PHP code that needs explicit trust roots
#                                passes CURLOPT_CAINFO.
#   --disable-static / --enable-shared — shared only.
#
# curl's configure compiles AND runs a sanity-check binary to verify that
# the libs it just link-tested are also runtime-loadable. Without a runtime
# library-search-path pointing at our bundled libssl/libcrypto/libnghttp2/
# libz, the test binary fails to dlopen them and configure aborts with
# "run-time libs availability... failed". We set PBS_RPATH_VAR
# (LD_LIBRARY_PATH on Linux, DYLD_LIBRARY_PATH on Darwin) only for the
# configure invocation — exporting it globally would cause cmake's own
# libcurl in other deps' builds to pick up the wrong libs.
env "$PBS_RPATH_VAR=${PBS_DEPS_LDPATH:-}" \
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

# Build only the library + headers, skip docs/. curl's docs/ subdir
# uses scripts/cd2nroff to convert .md sources to nroff(7) man pages,
# and that script has `#!/usr/bin/env perl` which the Nix build sandbox
# can't resolve (no /usr/bin/env). PHP's curl extension consumes
# libcurl + headers + curl.pc — never the man pages — so skipping docs
# is the right trade-off.
make -j"$NIX_BUILD_CORES" -C lib
make -j"$NIX_BUILD_CORES" -C include
make -C lib install
make -C include install
# Install the .pc files for downstream pkg-config consumers.
make install-pkgconfigDATA 2>/dev/null || \
  make -C . install-data-am 2>/dev/null || \
  cp libcurl.pc "$PBS_DEPS/lib/pkgconfig/" 2>/dev/null || true

# Drop the curl CLI binary; PHP's curl extension uses libcurl directly and
# the CLI would otherwise need its own RPATH/finalize handling.
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libcurl.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libcurl
echo "libcurl OK"
