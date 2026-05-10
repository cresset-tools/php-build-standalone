# openjpeg bundled-dep derivation. JPEG 2000 (.jp2) codec used as an
# ImageMagick delegate (--with-jp2 / --with-openjp2). Cmake-based;
# uses our bundled libpng + libtiff + lcms2 + zlib for the example
# converters, but we disable the converters anyway (BUILD_CODEC=OFF)
# since IM consumes only libopenjp2.
#
# The github-archive tarball extracts to openjpeg-<version>/, so the
# default srcSubdir works.
{ mkDep, zlib, libpng, libtiff, lcms2 }:
mkDep {
  name = "openjpeg";
  deps = [ zlib libpng libtiff lcms2 ];
}
