#!/usr/bin/env bash
# Build Oniguruma (libonig) as a shared library into ${PBS_DEPS}.
#
# PHP's mbstring extension links against libonig.so for its mb_ereg /
# mb_split family of regex functions. We ship a bundled copy so the
# tarball doesn't depend on the host's libonig.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh.

set -euo pipefail

: "${PBS_SRC_ONIGURUMA:?}"
: "${PBS_VER_ONIGURUMA:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

# Upstream tarball extracts as onig-<version>/, NOT oniguruma-<version>/.
# Our internal dep key is "oniguruma" (matches the PHP-side --with-onig
# convention and is more discoverable than "onig"), but the tarball name
# follows upstream's onig-* convention. Keep the two distinct.
src_dir="$PBS_SOURCES/onig-${PBS_VER_ONIGURUMA}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ONIGURUMA" -C "$PBS_SOURCES"
cd "$src_dir"

# Plain autotools build. Oniguruma has no external runtime deps beyond
# libc, so there's nothing to point configure at.
#   --disable-static / --enable-shared — shared only, matching the rest
#                                        of the PBS-style tree.
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$(nproc)"
make install

# Drop bin/onig-config — it's a config-helper script with the build-time
# /nix/store prefix hardcoded into it, and PHP's mbstring extension uses
# pkg-config (the .pc file we keep in lib/pkgconfig/) to find oniguruma
# rather than this script.
rm -rf "$PBS_DEPS/bin"

# Sanity: shared lib must exist with a clean NEEDED list (no /nix/store
# leakage from the cc-wrapper-free toolchain).
lib="$PBS_DEPS/lib/libonig.so"
real_lib="$(readlink -f "$lib")"
echo
echo "--- oniguruma NEEDED audit ---"
needed=$(readelf -d "$real_lib" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: libonig has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "oniguruma OK"
