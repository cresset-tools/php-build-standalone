#!/usr/bin/env bash
# Build zstd.so/.dylib (the zstd PHP extension) against our just-built PHP.
#
# Mirrors build-ev.sh: phpize + configure + make + staged install, with
# the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.
#
# No external C library: the source tarball vendors its library
# (zstd/lib/, libzstd 1.5.7 as of 0.18.0), and config.m4 compiles it
# in-tree when no system library is requested (--without-libzstd). The
# compressor is therefore statically part of zstd.so, and the
# extension's store closure is just PHP's. See php/zstd.nix.
#
# --disable-apcu: config.m4 defaults the APCu serializer integration to
# `auto`, which turns it on whenever apcu's headers happen to sit in
# PHP's include dir. They never do here (apcu is its own derivation),
# but spelling it out keeps the result independent of that.

set -euo pipefail

: "${PBS_SRC_ZSTD:?}"
: "${PBS_VER_ZSTD:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?zstd needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/zstd-${PBS_VER_ZSTD}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ZSTD" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-zstd \
  --without-libzstd \
  --disable-apcu

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into zstd's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

so="$(find "$PBS_DEPS/__staging" -name zstd.so -type f | head -1)"
if [ -z "$so" ]; then
  echo "FATAL: zstd.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" zstd.so
echo "zstd OK ($rel)"
