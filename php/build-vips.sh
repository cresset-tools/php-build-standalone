#!/usr/bin/env bash
# Build vips.so/.dylib (the php-vips PECL extension) against our
# just-built PHP and bundled libvips.
#
# Mirrors build-imagick.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.

set -euo pipefail

: "${PBS_SRC_VIPS:?}"
: "${PBS_VER_VIPS:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?vips needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_LIBVIPS:?vips needs libvips headers + libs}"

src_dir="$PBS_SOURCES/vips-${PBS_VER_VIPS}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_VIPS" -C "$PBS_SOURCES"
cd "$src_dir"

# php-vips 1.0.13 calls vips_snprintf(), which libvips removed in 8.13
# (it was always just a back-compat alias for g_snprintf). Substitute
# inline so the extension builds against current libvips. Upstream
# php-vips has not had a release that fixes this.
sed -i 's/\bvips_snprintf\b/g_snprintf/g' vips.c

# vips's config.m4 calls `pkg-config vips --cflags --libs`. Point it at
# our bundled libvips so it doesn't auto-detect a host install. The
# transitive glib + image-format pkgconfig dirs aren't needed here —
# vips.pc lists them in Requires: and pkg-config follows the chain via
# PKG_CONFIG_PATH only if the .pc files are reachable; we add them so
# pkg-config can resolve the full Cflags/Libs closure.
export PKG_CONFIG_PATH="$PBS_DEP_LIBVIPS/lib/pkgconfig:$PBS_DEP_GLIB/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --with-vips

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into vips's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

vips_so="$(find "$PBS_DEPS/__staging" -name vips.so -type f | head -1)"
if [ -z "$vips_so" ]; then
  echo "FATAL: vips.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${vips_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$vips_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" vips.so
echo "vips OK ($rel)"
