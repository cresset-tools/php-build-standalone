#!/usr/bin/env bash
# Build libxml2 as a shared library into ${PBS_DEPS}, with zlib support.
#
# Inherits CC, CFLAGS, LDFLAGS, plus PBS_DEP_ZLIB pointing at the zlib
# derivation's $out (auto-appended -I/-L by mkDep).

set -euo pipefail

: "${PBS_SRC_LIBXML2:?}"
: "${PBS_VER_LIBXML2:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?libxml2 needs zlib}"

src_dir="$PBS_SOURCES/libxml2-${PBS_VER_LIBXML2}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBXML2" -C "$PBS_SOURCES"
cd "$src_dir"

# Configure flags rationale:
#   --without-python      — no Python bindings.
#   --without-lzma        — skip xz support; PHP's xml extensions don't
#                           use it. Avoids needing a bundled xz dep.
#   --without-iconv       — DELIBERATE. libxml2 normally autodetects glibc's
#                           iconv. Letting it bind to the system iconv would
#                           couple the tarball to the host's glibc symbol
#                           versions in ways our manylinux strategy hasn't
#                           accounted for yet (deferred to v2). UTF-8 source
#                           XML still works without iconv.
#   --with-zlib=$DEP      — point libxml2 at the bundled zlib's prefix.
#   --disable-static      — shared only.
#   --enable-shared       — explicit (defense in depth).
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --without-python \
  --without-lzma \
  --without-iconv \
  --with-zlib="$PBS_DEP_ZLIB" \
  --disable-static \
  --enable-shared

# Build only the shared library, NOT the xmlcatalog/xmllint helper
# executables. They aren't needed by PHP, and on Linux trying to build
# them trips a binutils-2.22+ linker quirk (libtool's xmlcatalog/xmllint
# rules don't propagate -lm/-lz transitively through positional libxml2.so
# arg, link fails with bogus undefined references to log10/fmod/gzread).
make -j"$NIX_BUILD_CORES" libxml2.la

# Install only what PHP and downstream extension builds will look for:
#   - libxml2.so* / libxml2.dylib* via libtool (handles symlinks + .la)
#   - include/libxml/*.h headers
#   - libxml-2.0.pc (pkg-config consumers)
make install-libLTLIBRARIES install-pkgconfigDATA
make -C include install

lib="$PBS_DEPS/lib/libxml2.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libxml2
echo "libxml2 OK"
