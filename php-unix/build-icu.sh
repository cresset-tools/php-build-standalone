#!/usr/bin/env bash
# Build ICU (International Components for Unicode) as shared libraries into
# ${PBS_DEPS}. Used by PHP's intl extension.
#
# ICU is the FIRST C++ dep in php-build-standalone. We deliberately
# static-link the C++ runtime (-static-libstdc++ -static-libgcc) for two
# reasons:
#
#   1. Bootstrap problem: ICU's build runs its own freshly-built C++ tool
#      `icupkg` to assemble the unicode data archive. icupkg has DT_NEEDED
#      libstdc++.so.6, but at that point libstdc++ is only at gcc-unwrapped's
#      store path — not on LD_LIBRARY_PATH for the build, and not yet
#      installed anywhere ICU can find it. With -static-libstdc++, icupkg
#      has no runtime C++ dep at all and just runs.
#
#   2. Portability: shipping libstdc++.so.6 in our tarball would couple
#      consumers to whichever libstdc++/glibc-symbol-version we were built
#      against. Static-linking it into each libicu*.so makes the .so files
#      a few MB larger but keeps the consumer-side dependency surface flat
#      (just glibc).
#
# PHP's intl extension links against libicu*.so via PHP's C API, never
# directly against libstdc++ — so the static-link is invisible to PHP code.
#
# Source layout quirk: the tarball extracts to a top-level `icu/` directory
# (not `icu-75.1/`), and the configure script lives at `source/configure`,
# not the top level. ICU ships a `runConfigureICU <platform>` wrapper that
# applies sensible per-platform defaults; we use that wrapper.

set -euo pipefail

: "${PBS_SRC_ICU:?}"
: "${PBS_VER_ICU:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_root="$PBS_SOURCES/icu-${PBS_VER_ICU}"
rm -rf "$src_root"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ICU" -C "$PBS_SOURCES"
# Tarball top-level is `icu/`; rename to a versioned dir for clarity and to
# avoid collisions with any future ICU build sharing $PBS_SOURCES.
mv "$PBS_SOURCES/icu" "$src_root"
cd "$src_root/source"

# Configure flags rationale:
#   --disable-static / --enable-shared — we ship .so only, like every other
#     bundled dep.
#   --disable-tests / --disable-samples / --disable-extras — saves several
#     minutes of build time and avoids extra binaries we'd otherwise have
#     to clean up post-install. PHP only needs the libraries + headers.
#   --libdir overrides ICU's default of $prefix/lib64 on some hosts to keep
#     all bundled libs in $PBS_DEPS/lib uniformly.
# -static-libstdc++ / -static-libgcc are gcc driver flags that take effect
# at link time; passing them via LDFLAGS works for both the .so build and
# the icupkg executable.
export LDFLAGS="$LDFLAGS -static-libstdc++ -static-libgcc"

./runConfigureICU Linux \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --disable-tests \
  --disable-samples \
  --disable-extras

make -j"$(nproc)"
make install

# ICU ships several shell helpers in $prefix/bin (icu-config, gencnval,
# makeconv, …) and possibly $prefix/sbin. PHP's intl extension uses
# pkg-config (icu-uc.pc / icu-i18n.pc), not icu-config, and we don't ship
# the helper binaries. icu-config in particular has a hardcoded
# `prefix=...` line that would break the relocatability audit.
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/sbin"

# lib/icu/<version>/ contains Makefile.inc and pkgdata.inc — build-helper
# fragments for users who want to assemble custom ICU data packages from
# PHP's perspective these are dead weight, AND they hardcode the build-time
# /nix/store prefix into variables like ICUPREFIX/CC/CXX/etc. which fails
# the relocatability audit. PHP only consumes libicu*.so + headers + .pc.
rm -rf "$PBS_DEPS/lib/icu"

# share/icu/<version>/ similarly contains build helpers (install-sh,
# mkinstalldirs, makedata makefiles) with build-time paths. Drop entirely;
# PHP's intl extension does not consume them.
rm -rf "$PBS_DEPS/share/icu"

# Sanity audit: the four libs PHP's intl needs must exist with clean
# DT_NEEDED (no /nix/store leaks). libstdc++.so.6 is allowed and expected.
echo
echo "--- ICU NEEDED audit ---"
for libname in libicuuc libicui18n libicudata libicuio; do
  lib="$PBS_DEPS/lib/${libname}.so"
  if [ ! -e "$lib" ]; then
    echo "FATAL: missing $lib" >&2
    exit 1
  fi
  real_lib="$(readlink -f "$lib")"
  echo "# ${libname}:"
  needed=$(readelf -d "$real_lib" | grep NEEDED || true)
  echo "$needed"
  if echo "$needed" | grep -q '/nix/store'; then
    echo "FATAL: ${libname} has /nix/store path in DT_NEEDED" >&2
    exit 1
  fi
done
echo "ICU OK"
