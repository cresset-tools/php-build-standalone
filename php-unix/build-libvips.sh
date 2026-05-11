#!/usr/bin/env bash
# Build libvips into ${PBS_DEPS}.
#
# meson + ninja. We start with --auto-features=disabled to lock out
# meson's pkg-config-based auto-detection (which would otherwise pull
# in any host system delegate it can find), then opt back in only the
# image format deps we already bundle: jpeg, png, tiff, webp, heif,
# lcms. Everything else stays off — fft, orc, librsvg, rsvg, openexr,
# poppler, openslide, openjpeg-via-libvips, pdfium, matio, niftiio,
# imagequant, libexif, magick, archive, fontconfig, pangocairo.
#
# C++ API and gobject-introspection are also disabled — the vips PECL
# extension consumes the C API only, and disabling them shaves real
# build time and removes the libvips-cpp.so + libvips-gir-* outputs.

set -euo pipefail

: "${PBS_SRC_LIBVIPS:?}"
: "${PBS_VER_LIBVIPS:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_GLIB:?}"
: "${PBS_DEP_LIBPNG:?}"
: "${PBS_DEP_LIBJPEG_TURBO:?}"
: "${PBS_DEP_LIBWEBP:?}"
: "${PBS_DEP_LIBTIFF:?}"
: "${PBS_DEP_LIBHEIF:?}"
: "${PBS_DEP_LCMS2:?}"
: "${PBS_DEP_LIBXML2:?}"
: "${PBS_DEP_ZLIB:?}"
: "${PBS_DEP_EXPAT:?}"

# upstream tarball extracts to vips-<version>/, not libvips-<version>/.
src_dir="$PBS_SOURCES/vips-${PBS_VER_LIBVIPS}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBVIPS" -C "$PBS_SOURCES"
cd "$src_dir"

# meson resolves every delegate via pkg-config. Glib transitively pulls
# in libffi + pcre2's pkgconfig dirs through Requires:; we still list
# glib explicitly for the GObject / GIO bits. libxml2 is a transitive
# dep of libheif and a few core libvips features, so it's listed too.
export PKG_CONFIG_PATH="$PBS_DEP_GLIB/lib/pkgconfig:$PBS_DEP_LIBPNG/lib/pkgconfig:$PBS_DEP_LIBJPEG_TURBO/lib/pkgconfig:$PBS_DEP_LIBWEBP/lib/pkgconfig:$PBS_DEP_LIBTIFF/lib/pkgconfig:$PBS_DEP_LIBHEIF/lib/pkgconfig:$PBS_DEP_LCMS2/lib/pkgconfig:$PBS_DEP_LIBXML2/lib/pkgconfig:$PBS_DEP_ZLIB/lib/pkgconfig:$PBS_DEP_EXPAT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# See build-glib.sh — meson's -Werror=unused-command-line-argument trips
# on the link-side flags baked into our CC wrapper. -Qunused-arguments
# is clang's persistent silencer for the warning.
export CFLAGS="$CFLAGS -Qunused-arguments"
export CXXFLAGS="$CXXFLAGS -Qunused-arguments"

build_dir="$src_dir/build"
rm -rf "$build_dir"

meson setup "$build_dir" \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --default-library=shared \
  --buildtype=release \
  --auto-features=disabled \
  -Dexamples=false \
  -Dcplusplus=false \
  -Ddoxygen=false \
  -Dgtk_doc=false \
  -Dvapi=false \
  -Dintrospection=disabled \
  -Dmodules=disabled \
  -Ddeprecated=false \
  -Djpeg=enabled \
  -Dpng=enabled \
  -Dtiff=enabled \
  -Dwebp=enabled \
  -Dheif=enabled \
  -Dlcms=enabled \
  -Dzlib=enabled

ninja -C "$build_dir" -j"$NIX_BUILD_CORES"
ninja -C "$build_dir" install

# Drop tooling we don't ship: bin/vips, vipsedit, vipsthumbnail, vipsheader,
# vipsdisp, batch_image_convert, batch_crop, etc. They bake build-time
# RPATHs and aren't needed by the PHP extension. share/man, share/doc,
# share/locale similarly.
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/share/man"
rm -rf "$PBS_DEPS/share/doc"
rm -rf "$PBS_DEPS/share/locale"
rm -rf "$PBS_DEPS/share/bash-completion"
rm -rf "$PBS_DEPS/share/zsh"

lib="$PBS_DEPS/lib/libvips.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libvips
echo "libvips OK"
