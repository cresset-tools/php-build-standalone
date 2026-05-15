#!/usr/bin/env bash
# Build libxslt as a shared library into ${PBS_DEPS}, against bundled
# libxml2.
#
# Inherits CC, CFLAGS, LDFLAGS, plus PBS_DEP_LIBXML2 / PBS_DEP_ZLIB
# pointing at the respective dep prefixes (auto-appended -I/-L by mkDep).

set -euo pipefail

: "${PBS_SRC_LIBXSLT:?}"
: "${PBS_VER_LIBXSLT:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_LIBXML2:?libxslt needs libxml2}"
: "${PBS_DEP_ZLIB:?libxslt needs zlib (libxml2 transitive)}"

src_dir="$PBS_SOURCES/libxslt-${PBS_VER_LIBXSLT}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBXSLT" -C "$PBS_SOURCES"
cd "$src_dir"

# libxslt 1.1.42+ detects libxml2 via pkg-config when neither
# --with-libxml-prefix nor LIBXML_LIBS is set (configure.ac line ~405).
# We have libxml-2.0.pc in our libxml2's prefix but no xml2-config binary
# (build-libxml2.sh installs the .so/headers/.pc only), so go the
# pkg-config route. --with-libxml-prefix would set LIBXML_CFLAGS="-I$DEP"
# directly, which misses the /include/libxml2 subdirectory libxml2
# actually installs into — the .pc file gets it right.
export PKG_CONFIG_PATH="$PBS_DEP_LIBXML2/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Configure flags rationale:
#   --without-python          — no Python bindings.
#   --without-crypto          — skip libgcrypt EXSLT crypto module. PHP's
#                               xsl extension doesn't expose EXSLT crypto,
#                               and pulling in libgcrypt+libgpg-error here
#                               would expand the dep graph for zero gain.
#   --without-debugger        — drop xsldbg (xsltproc -dbg). Not consumed
#                               by PHP, not shipped in the tarball.
#   --without-debug           — disable internal debug tracing (-DDEBUG).
#   --without-mem-debug       — disable libxslt's allocator-tracking shims.
#   --without-plugins         — disable runtime extension-module loading;
#                               libxslt's plugin path would otherwise bake
#                               $libdir/libxslt-plugins into rodata. PHP's
#                               xsl extension doesn't use it.
#   --disable-static          — shared only.
#   --enable-shared           — explicit (defense in depth).
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --without-python \
  --without-crypto \
  --without-debugger \
  --without-debug \
  --without-mem-debug \
  --without-plugins \
  --disable-static \
  --enable-shared

# Build only the shared libraries (libxslt + libexslt). Skip the xsltproc
# CLI tool — it isn't consumed by PHP, and building it pulls the same
# libtool transitive-link issue libxml2's xmllint hit (binutils 2.22+
# refuses positional .so args without -l propagation).
make -j"$NIX_BUILD_CORES" -C libxslt libxslt.la
make -j"$NIX_BUILD_CORES" -C libexslt libexslt.la

# Install only what PHP's ext/xsl needs:
#   - libxslt.so* / libexslt.so* (+ .dylib counterparts on Darwin)
#   - include/libxslt/*.h, include/libexslt/*.h (both distributed and
#     nodist_*HEADERS targets — xsltconfig.h / exsltconfig.h are
#     configure-generated and live under the nodist_* target)
#   - libxslt.pc / libexslt.pc (pkg-config consumers, installed by the
#     ROOT Makefile's install-pkgconfigDATA target, not the per-subdir
#     Makefiles)
make -C libxslt   install-libLTLIBRARIES install-xsltincHEADERS install-nodist_xsltincHEADERS
make -C libexslt  install-libLTLIBRARIES install-exsltincHEADERS install-nodist_exsltincHEADERS
make install-pkgconfigDATA

for lib in libxslt libexslt; do
  path="$PBS_DEPS/lib/${lib}.${PBS_LIB_EXT}"
  [ -e "$path" ] || { echo "FATAL: $path not produced" >&2; exit 1; }
  pbs_audit_lib "$path" "$lib"
done
echo "libxslt OK"
