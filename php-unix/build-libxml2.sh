#!/usr/bin/env bash
# Build libxml2 as a shared library into ${PBS_DEPS}, with zlib support.
#
# Inherits CC, CFLAGS, LDFLAGS, plus PBS_DEP_ZLIB pointing at the zlib
# derivation's $out (auto-appended -I/-L by mkDep.nix).

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
#   --without-python      — no Python bindings (we don't ship a pythonized
#                           libxml2 in the PHP tarball).
#   --without-lzma        — skip xz support; PHP's xml extensions don't use
#                           it. Avoids needing a bundled xz dep.
#   --without-iconv       — DELIBERATE. libxml2 normally autodetects glibc's
#                           iconv via headers in $GLIBC_DEV/include. Letting
#                           it bind to the system iconv would couple the
#                           tarball to the host's glibc symbol versions in
#                           ways our manylinux strategy hasn't accounted for
#                           yet (deferred to v2). UTF-8 source XML still
#                           works without iconv.
#   --with-zlib=$DEP      — point libxml2 at the bundled zlib's prefix.
#                           libxml2's configure looks for zlib.h there.
#   --disable-static      — shared only.
#   --enable-shared       — explicit even though autotools default for
#                           libtool projects (defense in depth).
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
# executables. They aren't needed by PHP (and trying to build them
# trips a binutils-2.22+ linker quirk: when an executable links against
# a shared lib via positional arg, ld doesn't walk that lib's DT_NEEDED
# transitively, and libtool's xmlcatalog/xmllint link rules don't
# propagate -lm/-lz themselves, so the link fails with bogus undefined
# references to log10/fmod/gzread despite libxml2.so itself being
# correctly linked. Sidestep by just skipping those targets.
make -j"$(nproc)" libxml2.la

# Install only what PHP and downstream extension builds will look for:
#   - libxml2.so* into $PBS_DEPS/lib via libtool (handles symlinks + .la)
#   - include/libxml/*.h headers (PHP's xml ext #includes them)
#   - libxml-2.0.pc (php-config / pkg-config consumers)
make install-libLTLIBRARIES install-pkgconfigDATA
make -C include install

# Sanity: shared lib must exist with a clean NEEDED list.
lib="$PBS_DEPS/lib/libxml2.so"
real_lib="$(readlink -f "$lib")"
echo
echo "--- libxml2 NEEDED audit ---"
needed=$(readelf -d "$real_lib" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: libxml2 has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "libxml2 OK"
