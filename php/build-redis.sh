#!/usr/bin/env bash
# Build redis.so/.dylib (the phpredis PECL extension) against our
# just-built PHP.
#
# Mirrors build-imagick.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.
#
# No external C library is required — phpredis speaks the redis wire
# protocol directly. Optional serializer/compression backends (igbinary,
# msgpack, lzf, zstd, lz4) are intentionally not enabled; they'd each
# need their own bundled dep and are typically opt-in.

set -euo pipefail

: "${PBS_SRC_REDIS:?}"
: "${PBS_VER_REDIS:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?redis needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/redis-${PBS_VER_REDIS}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_REDIS" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-redis

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into redis's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

redis_so="$(find "$PBS_DEPS/__staging" -name redis.so -type f | head -1)"
if [ -z "$redis_so" ]; then
  echo "FATAL: redis.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${redis_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$redis_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" redis.so
echo "redis OK ($rel)"
