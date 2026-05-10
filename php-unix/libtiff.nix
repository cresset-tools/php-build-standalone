# libtiff bundled-dep derivation. TIFF reader/writer used as an
# ImageMagick delegate (--with-tiff). Depends on zlib (DEFLATE) and
# libjpeg-turbo (JPEG-in-TIFF). lzma/zstd backends are disabled to
# match the rest of the bundle.
#
# We drop bin/ (tiffcp / tiffinfo / etc) so build-time prefix doesn't
# leak into a CLI's RPATH. PHP / imagick consume the library only.
{ mkDep, zlib, libjpeg-turbo }:
mkDep {
  name = "libtiff";
  builder = "autotools";
  deps = [ zlib libjpeg-turbo ];
  configureFlags = [
    "--disable-lzma"
    "--disable-zstd"
    "--disable-webp"
    "--disable-libdeflate"
    "--disable-cxx"
    "--disable-docs"
    "--disable-tests"
    "--disable-tools"
  ];
  postInstallCleanup = [ "bin" "share" ];
  auditLibs = [ "libtiff" ];
}
