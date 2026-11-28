#!/usr/bin/env bash
# Build lz4.so/.dylib (the lz4 PHP extension) against our just-built PHP.
#
# Mirrors build-ev.sh: phpize + configure + make + staged install, with
# the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.
#
# No external C library: the source tarball vendors its library
# (lz4/lib/, liblz4 1.10.0 as of 0.8.0), and config.m4 compiles it
# in-tree when no system library is requested. The compressor is
# therefore statically part of lz4.so, and the extension's store
# closure is just PHP's. See php/lz4.nix.
#
# --disable-apcu: config.m4 defaults the APCu serializer integration to
# `auto`, which turns it on whenever apcu's headers happen to sit in
# PHP's include dir. They never do here (apcu is its own derivation),
# but spelling it out keeps the result independent of that.

set -euo pipefail

: "${PBS_SRC_LZ4:?}"
: "${PBS_VER_LZ4:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?lz4 needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/lz4-${PBS_VER_LZ4}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LZ4" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-lz4 \
  --disable-apcu

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into lz4's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

so="$(find "$PBS_DEPS/__staging" -name lz4.so -type f | head -1)"
if [ -z "$so" ]; then
  echo "FATAL: lz4.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" lz4.so
echo "lz4 OK ($rel)"
