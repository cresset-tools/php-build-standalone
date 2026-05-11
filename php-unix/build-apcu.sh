#!/usr/bin/env bash
# Build apcu.so/.dylib (the PECL APCu userspace cache extension) against
# our just-built PHP. Pure C, no external library — uses POSIX shm/mmap
# only. Same shape as build-redis.sh / build-igbinary.sh.
#
# We omit --enable-apcu-bc (the APC backwards-compat shim), which would
# install a second apc.so wrapping APCu's surface. Modern PHP code targets
# APCu directly; the BC layer is for codebases stuck on the legacy ext-apc
# API removed from PHP 7.

set -euo pipefail

: "${PBS_SRC_APCU:?}"
: "${PBS_VER_APCU:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?apcu needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/apcu-${PBS_VER_APCU}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_APCU" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-apcu

make -j"$NIX_BUILD_CORES"

make install INSTALL_ROOT="$PBS_DEPS/__staging"

apcu_so="$(find "$PBS_DEPS/__staging" -name apcu.so -type f | head -1)"
if [ -z "$apcu_so" ]; then
  echo "FATAL: apcu.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${apcu_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$apcu_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" apcu.so
echo "apcu OK ($rel)"
