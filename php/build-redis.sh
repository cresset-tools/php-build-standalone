#!/usr/bin/env bash
# Build redis.so/.dylib (the phpredis PECL extension) against our
# just-built PHP.
#
# Mirrors build-imagick.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.
#
# Optional backends enabled here (see php/redis.nix for why the
# serializers igbinary/msgpack stay off):
#   --enable-redis-zstd      libzstd via pkg-config (--with-libzstd
#       defaults to yes, which is the pkg-config path).
#   --enable-redis-lz4       liblz4 via pkg-config; --with-liblz4 has to be
#       passed explicitly because it defaults to no, and "no" is rejected
#       with "only system liblz4 is supported".

set -euo pipefail

: "${PBS_SRC_REDIS:?}"
: "${PBS_VER_REDIS:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?redis needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_ZSTD:?redis needs the bundled zstd dep}"
: "${PBS_DEP_LZ4:?redis needs the bundled lz4 dep}"

src_dir="$PBS_SOURCES/redis-${PBS_VER_REDIS}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_REDIS" -C "$PBS_SOURCES"
cd "$src_dir"

export PKG_CONFIG_PATH="$PBS_DEP_ZSTD/lib/pkgconfig:$PBS_DEP_LZ4/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-redis \
  --enable-redis-zstd \
  --enable-redis-lz4 \
  --with-liblz4

# Guard against a silently dropped flag (a typo'd --enable-* is only a
# configure warning): every backend must have made it into config.h.
for def in HAVE_REDIS_ZSTD HAVE_REDIS_LZ4; do
  grep -q "^#define $def 1" config.h || { echo "FATAL: $def not set in config.h" >&2; exit 1; }
done

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
