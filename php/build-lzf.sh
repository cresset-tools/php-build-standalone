#!/usr/bin/env bash
# Build lzf.so/.dylib (the lzf PHP extension) against our just-built PHP.
#
# Mirrors build-ev.sh: phpize + configure + make + staged install, with
# the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.
#
# No external C library: the source tarball vendors liblzf (lib/), and
# config.m4 compiles it in-tree when no system library is requested.
# The compressor is therefore statically part of lzf.so, and the
# extension's store closure is just PHP's. See php/lzf.nix.

set -euo pipefail

: "${PBS_SRC_LZF:?}"
: "${PBS_VER_LZF:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?lzf needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/LZF-${PBS_VER_LZF}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LZF" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-lzf

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into lzf's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

so="$(find "$PBS_DEPS/__staging" -name lzf.so -type f | head -1)"
if [ -z "$so" ]; then
  echo "FATAL: lzf.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" lzf.so
echo "lzf OK ($rel)"
