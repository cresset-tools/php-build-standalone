# libvips bundled-dep derivation. Provides libvips.so/.dylib (the C API
# the vips PECL extension consumes), plus libvips-cpp (header-only
# wrapper, not used at runtime). Built minimal: only the image format
# delegates we already bundle.
#
# Enabled delegates (via existing bundled deps):
#   libpng / libjpeg-turbo / libwebp / libtiff / libheif / lcms2.
#   zlib + libxml2 are also pulled in transitively from glib + libheif.
#
# Explicitly disabled (per the design call to keep the dep graph small):
#   fft (fftw3), orc, librsvg, openexr, poppler, openslide, pdfium,
#   matio, niftiio, libimagequant, libexif, magick (ImageMagick is
#   bundled but we don't link libvips against it — imagick.so already
#   covers IM use cases; libvips-via-IM would be redundant), cgif,
#   archive, fontconfig, pangocairo.
#
# meson-based; build-libvips.sh handles the configure + ninja invocation.
{ mkDep, glib, libpng, libjpeg-turbo, libwebp, libtiff, libheif, lcms2
, libxml2, zlib, expat }:
mkDep {
  name = "libvips";
  deps = [
    glib libpng libjpeg-turbo libwebp libtiff libheif lcms2
    libxml2 zlib expat
  ];
}
