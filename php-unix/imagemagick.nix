# ImageMagick bundled-dep derivation. Provides libMagickCore, libMagickWand
# (the C API the imagick PECL extension consumes), and headers under
# include/ImageMagick-7/. Imagick links against libMagickWand only at
# runtime, but configure-time pulls in MagickCore + delegate metadata.
#
# Tarball name quirk: the github archive extracts to ImageMagick-<version>/
# (Pascal-cased), not imagemagick-<version>/. mkDep's default srcSubdir
# would produce the lowercase form; we override.
#
# Delegate set (matching imagemagick.url upstream's --enable-shared
# convention):
#   in: zlib bzip2 libpng libjpeg-turbo libwebp freetype libxml2
#       libtiff lcms2 openjpeg libheif (transitively libde265)
#   out (explicitly disabled): rsvg, ghostscript, raw, openexr, djvu,
#       jbig, lzma, fftw, fpx, fontconfig, x11, perl, c++ bindings.
#
# build-imagemagick.sh handles the configure flags. We use buildScript
# rather than the autotools template because IM has ~50 --without-*
# flags that would clutter the .nix file.
{ mkDep, zlib, bzip2, libpng, libjpeg-turbo, libwebp, freetype, libxml2
, libtiff, lcms2, openjpeg, libheif, libde265
}:
mkDep {
  name = "imagemagick";
  deps = [
    zlib bzip2 libpng libjpeg-turbo libwebp freetype libxml2
    libtiff lcms2 openjpeg libheif libde265
  ];
  # The github archive extracts to ImageMagick-<v>/ (Pascal-cased);
  # build-imagemagick.sh handles that explicitly.
}
