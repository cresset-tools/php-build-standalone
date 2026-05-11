#!/usr/bin/env bash
# Build igbinary.so/.dylib (the PECL extension) against our just-built PHP.
#
# Mirrors build-redis.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.
#
# No external C library is required — igbinary's serializer is implemented
# entirely in C alongside PHP's headers.

set -euo pipefail

: "${PBS_SRC_IGBINARY:?}"
: "${PBS_VER_IGBINARY:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?igbinary needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/igbinary-${PBS_VER_IGBINARY}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_IGBINARY" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-igbinary

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-redis.sh: php-config reports
# PHP's $out as extension_dir, but we install into igbinary's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

igbinary_so="$(find "$PBS_DEPS/__staging" -name igbinary.so -type f | head -1)"
if [ -z "$igbinary_so" ]; then
  echo "FATAL: igbinary.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${igbinary_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$igbinary_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" igbinary.so
echo "igbinary OK ($rel)"
