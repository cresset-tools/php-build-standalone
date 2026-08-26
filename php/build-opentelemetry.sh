#!/usr/bin/env bash
# Build opentelemetry.so/.dylib (the opentelemetry PECL extension)
# against our just-built PHP. zend_observer bridge; see
# php/opentelemetry.nix.
#
# Mirrors build-redis.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so
# tarball-extension.nix can package it as a separately addressable
# extension artifact.
#
# No external C library — upstream's config.m4 leaves every dependency
# probe commented out and PHP_NEW_EXTENSION names only opentelemetry.c
# and otel_observer.c, so the manifest closure comes out empty.

set -euo pipefail

: "${PBS_SRC_OPENTELEMETRY:?}"
: "${PBS_VER_OPENTELEMETRY:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?opentelemetry needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/opentelemetry-${PBS_VER_OPENTELEMETRY}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_OPENTELEMETRY" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-opentelemetry

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into opentelemetry's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

otel_so="$(find "$PBS_DEPS/__staging" -name opentelemetry.so -type f | head -1)"
if [ -z "$otel_so" ]; then
  echo "FATAL: opentelemetry.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${otel_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$otel_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" opentelemetry.so
echo "opentelemetry OK ($rel)"
