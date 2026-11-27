#!/usr/bin/env bash
# Build memcached.so/.dylib (the php-memcached PECL extension) against our
# just-built PHP and bundled libmemcached.
#
# Mirrors build-uv.sh: phpize + configure + make + staged install, with
# the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.
#
# Configure choices:
#   --enable-memcached-session   memcached as a session.save_handler —
#       the main reason Magento/Symfony deployments install it. ext/session
#       is static in bin/php, so the ps_globals reference resolves against
#       the interpreter and no conf.d ordering is needed (contrast msgpack,
#       whose session hook is why it loads at 40-).
#   --enable-memcached-json      Memcached::SERIALIZER_JSON{,_ARRAY}. ext/json
#       is always compiled into PHP 8, so this costs no dependency.
#   --disable-memcached-igbinary / --disable-memcached-msgpack
#       Both would add PHP_ADD_EXTENSION_DEP → ZEND_MOD_REQUIRED, so
#       memcached.so would refuse to load without igbinary.so / msgpack.so.
#       Same call as phpredis (build-redis.sh): default feature set, no
#       cross-extension coupling the manifest can't express.
#   --disable-memcached-sasl     libmemcached is built without SASL.
#   --disable-memcached-protocol the Memcached\Server class; experimental
#       upstream and needs libevent.

set -euo pipefail

: "${PBS_SRC_MEMCACHED:?}"
: "${PBS_VER_MEMCACHED:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?memcached needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_LIBMEMCACHED:?memcached needs libmemcached headers + libs}"
: "${PBS_DEP_ZLIB:?memcached needs zlib (config.m4 hard-requires it)}"

src_dir="$PBS_SOURCES/memcached-${PBS_VER_MEMCACHED}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_MEMCACHED" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

# --with-libmemcached-dir makes config.m4 *replace* PKG_CONFIG_PATH with
# <dir>/lib/pkgconfig, so the probe cannot see a host libmemcached.pc.
./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-memcached \
  --with-libmemcached-dir="$PBS_DEP_LIBMEMCACHED" \
  --with-zlib-dir="$PBS_DEP_ZLIB" \
  --enable-memcached-session \
  --enable-memcached-json \
  --disable-memcached-igbinary \
  --disable-memcached-msgpack \
  --disable-memcached-sasl \
  --disable-memcached-protocol

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into memcached's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

memcached_so="$(find "$PBS_DEPS/__staging" -name memcached.so -type f | head -1)"
if [ -z "$memcached_so" ]; then
  echo "FATAL: memcached.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${memcached_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$memcached_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" memcached.so
echo "memcached OK ($rel)"
