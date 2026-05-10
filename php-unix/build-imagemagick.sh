#!/usr/bin/env bash
# Build ImageMagick (libMagickCore + libMagickWand) into ${PBS_DEPS}.
#
# Consumed by the imagick PECL extension via libMagickWand. We build
# the *library* with full delegate support; the convert/identify/etc
# CLIs are built but disabled-installed because they bake build-time
# RPATHs and aren't part of the redistribution.
#
# Quantum depth + HDRI: the defaults (Q16, HDRI on) match every
# mainstream distro packaging — imagick.so loaded against this build
# will produce results consistent with what users see on debian/alpine
# system PHP. Changing these would break image-content fingerprints in
# downstream tests.

set -euo pipefail

: "${PBS_SRC_IMAGEMAGICK:?}"
: "${PBS_VER_IMAGEMAGICK:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?}"
: "${PBS_DEP_BZIP2:?}"
: "${PBS_DEP_LIBPNG:?}"
: "${PBS_DEP_LIBJPEG_TURBO:?}"
: "${PBS_DEP_LIBWEBP:?}"
: "${PBS_DEP_FREETYPE:?}"
: "${PBS_DEP_LIBXML2:?}"
: "${PBS_DEP_LIBTIFF:?}"
: "${PBS_DEP_LCMS2:?}"
: "${PBS_DEP_OPENJPEG:?}"
: "${PBS_DEP_LIBHEIF:?}"
: "${PBS_DEP_LIBDE265:?}"

# github archive extracts to ImageMagick-<version>/ (Pascal-cased).
src_dir="$PBS_SOURCES/ImageMagick-${PBS_VER_IMAGEMAGICK}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_IMAGEMAGICK" -C "$PBS_SOURCES"
cd "$src_dir"

# Point pkg-config at every bundled dep so IM's configure picks them
# up rather than auto-detecting host system libs.
export PKG_CONFIG_PATH="$PBS_DEP_ZLIB/lib/pkgconfig:$PBS_DEP_BZIP2/lib/pkgconfig:$PBS_DEP_LIBPNG/lib/pkgconfig:$PBS_DEP_LIBJPEG_TURBO/lib/pkgconfig:$PBS_DEP_LIBWEBP/lib/pkgconfig:$PBS_DEP_FREETYPE/lib/pkgconfig:$PBS_DEP_LIBXML2/lib/pkgconfig:$PBS_DEP_LIBTIFF/lib/pkgconfig:$PBS_DEP_LCMS2/lib/pkgconfig:$PBS_DEP_OPENJPEG/lib/pkgconfig:$PBS_DEP_LIBHEIF/lib/pkgconfig:$PBS_DEP_LIBDE265/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Delegate selection: explicit on/off for everything we have an opinion
# about. Auto-detection is the failure mode here — IM's configure happily
# picks up host /usr/lib/* if you let it. Keep this list exhaustive.
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --disable-docs \
  --disable-deprecated \
  --disable-installed \
  --disable-openmp \
  --without-utilities \
  --without-magick-plus-plus \
  --without-perl \
  --without-x \
  --without-modules \
  --without-rsvg \
  --without-gslib \
  --without-gvc \
  --without-djvu \
  --without-dps \
  --without-fftw \
  --without-fpx \
  --without-fontconfig \
  --without-flif \
  --without-jbig \
  --without-lqr \
  --without-lzma \
  --without-openexr \
  --without-pango \
  --without-raqm \
  --without-raw \
  --without-wmf \
  --without-xml-config \
  --without-zstd \
  --with-zlib \
  --with-bzlib \
  --with-png \
  --with-jpeg \
  --with-webp \
  --with-tiff \
  --with-freetype \
  --with-xml \
  --with-lcms \
  --with-jp2 \
  --with-openjp2 \
  --with-heic \
  --with-quantum-depth=16 \
  --enable-hdri

make -j"$NIX_BUILD_CORES"
make install

# Strip etc/ + share/ (config-file boilerplate, docs we don't need at
# runtime). bin/ is preserved — under --without-utilities it contains
# only the *-config helpers (MagickCore-config, MagickWand-config,
# Magick++-config) that the imagick PECL configure consumes via
# --with-imagick=$PBS_DEP_IMAGEMAGICK. The /nix/store leaks in those
# scripts are detoxified by finalize-common.sh's text-file walk along
# with every other .pc / *-config we ship.
rm -rf "$PBS_DEPS/etc"
rm -rf "$PBS_DEPS/share"

# IM emits libMagickCore-7.Q16HDRI and libMagickWand-7.Q16HDRI (suffixes
# encode quantum/HDRI). Audit the canonical sonames.
for libname in "libMagickCore-7.Q16HDRI" "libMagickWand-7.Q16HDRI"; do
  lib="$PBS_DEPS/lib/${libname}.${PBS_LIB_EXT}"
  [ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
  pbs_audit_lib "$lib" "$libname"
done
echo "imagemagick OK"
