#!/usr/bin/env bash
# Build xdebug.so as a Zend extension against our just-built PHP, on Darwin.
# Mirrors php-unix/build-xdebug.sh: phpize comes from $PBS_DEP_PHP, which
# end-to-end-tests the relocation patches in scripts/phpize.in /
# scripts/php-config.in.

set -euo pipefail

: "${PBS_SRC_XDEBUG:?}"
: "${PBS_VER_XDEBUG:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?xdebug needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/xdebug-${PBS_VER_XDEBUG}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_XDEBUG" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config"

make -j"$(getconf _NPROCESSORS_ONLN)"

make install INSTALL_ROOT="$PBS_DEPS/__staging"

xdebug_so="$(find "$PBS_DEPS/__staging" -name xdebug.so -type f | head -1)"
if [ -z "$xdebug_so" ]; then
  echo "FATAL: xdebug.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${xdebug_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$xdebug_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

echo
echo "--- xdebug.so LC_LOAD_DYLIB audit ---"
otool -L "$PBS_DEPS$rel" || true
echo "xdebug OK ($rel)"
