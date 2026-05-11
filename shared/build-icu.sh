#!/usr/bin/env bash
# Build ICU (International Components for Unicode) as shared libraries
# into ${PBS_DEPS}. Used by PHP's intl extension.
#
# Platform-specific bits (target name, C++ runtime LDFLAGS) are passed
# in via extraEnv from icu.nix: PBS_ICU_TARGET, PBS_ICU_EXTRA_LDFLAGS.
# This script is OS-agnostic.
#
# PHP's intl extension links against libicu*.so/.dylib via PHP's C API,
# never directly against libstdc++/libc++ — so the runtime choice is
# invisible to PHP code.
#
# Source layout quirk: the tarball extracts to a top-level `icu/`
# directory (not `icu-75.1/`), and the configure script lives at
# `source/configure`. ICU ships a `runConfigureICU <platform>` wrapper
# we use.

set -euo pipefail

: "${PBS_SRC_ICU:?}"
: "${PBS_VER_ICU:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_ICU_TARGET:?set by icu.nix}"

src_root="$PBS_SOURCES/icu-${PBS_VER_ICU}"
rm -rf "$src_root"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ICU" -C "$PBS_SOURCES"
# Tarball top-level is `icu/`; rename to a versioned dir for clarity and
# to avoid collisions with any future ICU build sharing $PBS_SOURCES.
mv "$PBS_SOURCES/icu" "$src_root"
cd "$src_root/source"

# Apply Nix-supplied extra LDFLAGS (Linux: -static-libstdc++ -static-libgcc;
# Darwin: empty). These are gcc/clang driver flags that take effect at
# link time and apply to both .so and the icupkg executable that ICU
# runs internally.
export LDFLAGS="$LDFLAGS ${PBS_ICU_EXTRA_LDFLAGS:-}"

# Configure flags rationale:
#   --disable-static / --enable-shared — we ship .so/.dylib only.
#   --disable-tests / --disable-samples / --disable-extras — saves
#     several minutes of build time and avoids extra binaries.
#   --libdir overrides ICU's default of $prefix/lib64 on some hosts.
./runConfigureICU "$PBS_ICU_TARGET" \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --disable-tests \
  --disable-samples \
  --disable-extras

make -j"$NIX_BUILD_CORES"
make install

# ICU ships shell helpers in $prefix/bin (icu-config, gencnval, makeconv,
# …) and possibly $prefix/sbin. PHP's intl extension uses pkg-config
# (icu-uc.pc / icu-i18n.pc), not icu-config, and we don't ship the
# helper binaries. icu-config in particular has a hardcoded `prefix=...`
# line that would break the relocatability audit.
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/sbin"

# lib/icu/<version>/ contains Makefile.inc and pkgdata.inc — build-helper
# fragments that hardcode the build-time /nix/store prefix. PHP only
# consumes libicu*.{so,dylib} + headers + .pc.
rm -rf "$PBS_DEPS/lib/icu"

# share/icu/<version>/ similarly contains build helpers with build-time
# paths. PHP's intl extension does not consume them.
rm -rf "$PBS_DEPS/share/icu"

# Sanity audit: the four libs PHP's intl needs must exist. On Linux
# pbs_audit_lib also fails if any /nix/store path leaked into
# DT_NEEDED.
for libname in libicuuc libicui18n libicudata libicuio; do
  lib="$PBS_DEPS/lib/${libname}.${PBS_LIB_EXT}"
  if [ ! -e "$lib" ]; then
    echo "FATAL: missing $lib" >&2
    exit 1
  fi
  pbs_audit_lib "$lib" "ICU ${libname}"
done
echo "ICU OK"
