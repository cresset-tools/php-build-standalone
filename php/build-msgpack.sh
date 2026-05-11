#!/usr/bin/env bash
# Build msgpack.so/.dylib (the PECL MessagePack extension) against our
# just-built PHP. Pure C, no external library — same shape as build-redis.sh
# / build-igbinary.sh.
#
# --enable-msgpack-igbinary (which fuses msgpack's IS_IGBINARY support) is
# left off here. Enabling it would create an inter-PECL build-order
# dependency between igbinary.so and msgpack.so within the same PHP
# variant, which we don't currently model. Users who need it can rebuild
# msgpack themselves with --enable-msgpack-igbinary against the shipped
# headers via the relocated bin/phpize.

set -euo pipefail

: "${PBS_SRC_MSGPACK:?}"
: "${PBS_VER_MSGPACK:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?msgpack needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/msgpack-${PBS_VER_MSGPACK}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_MSGPACK" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-msgpack

make -j"$NIX_BUILD_CORES"

make install INSTALL_ROOT="$PBS_DEPS/__staging"

msgpack_so="$(find "$PBS_DEPS/__staging" -name msgpack.so -type f | head -1)"
if [ -z "$msgpack_so" ]; then
  echo "FATAL: msgpack.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${msgpack_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$msgpack_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" msgpack.so
echo "msgpack OK ($rel)"
