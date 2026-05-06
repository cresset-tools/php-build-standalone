#!/usr/bin/env bash
# Build Oniguruma (libonig) as a shared library into ${PBS_DEPS}.
#
# PHP's mbstring extension links against libonig for its mb_ereg /
# mb_split family of regex functions.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh).

set -euo pipefail

: "${PBS_SRC_ONIGURUMA:?}"
: "${PBS_VER_ONIGURUMA:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

# Upstream tarball extracts as onig-<version>/, NOT oniguruma-<version>/.
# Our internal dep key is "oniguruma" (matches the PHP-side --with-onig
# convention), but the tarball name follows upstream's onig-* convention.
src_dir="$PBS_SOURCES/onig-${PBS_VER_ONIGURUMA}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ONIGURUMA" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$PBS_NPROC"
make install

# Drop bin/onig-config — it's a config-helper script with the build-time
# /nix/store prefix hardcoded into it, and PHP's mbstring extension uses
# pkg-config (the .pc file we keep in lib/pkgconfig/) to find oniguruma
# rather than this script.
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libonig.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" oniguruma
echo "oniguruma OK"
