#!/usr/bin/env bash
# Build imagick.so/.dylib as a regular PHP extension against our
# just-built PHP and bundled ImageMagick.
#
# Like build-xdebug.sh, this exercises the phpize / php-config
# relocation patches end-to-end: $PBS_DEP_PHP/bin/phpize must resolve
# $prefix from $0 and emit build-files referencing $prefix/lib/php/build.

set -euo pipefail

: "${PBS_SRC_IMAGICK:?}"
: "${PBS_VER_IMAGICK:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?imagick needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_IMAGEMAGICK:?imagick needs ImageMagick (libMagickWand) headers + libs}"

src_dir="$PBS_SOURCES/imagick-${PBS_VER_IMAGICK}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_IMAGICK" -C "$PBS_SOURCES"
cd "$src_dir"

# imagick's configure consumes pkg-config to find ImageMagick; point it
# at our bundled IM. (--with-imagick=DIR is also accepted by some
# imagick versions but the PECL configure delegates to MagickWand.pc
# under the hood.)
export PKG_CONFIG_PATH="$PBS_DEP_IMAGEMAGICK/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --with-imagick="$PBS_DEP_IMAGEMAGICK"

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-xdebug.sh: php-config reports
# PHP's $out as extension_dir, but we install into imagick's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

imagick_so="$(find "$PBS_DEPS/__staging" -name imagick.so -type f | head -1)"
if [ -z "$imagick_so" ]; then
  echo "FATAL: imagick.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${imagick_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$imagick_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" imagick.so
echo "imagick OK ($rel)"
