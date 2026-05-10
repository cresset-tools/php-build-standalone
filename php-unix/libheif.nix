# libheif bundled-dep derivation. HEIF/HEIC container library used as
# an ImageMagick delegate (--with-heic). Cmake-based.
#
# Decode-only configuration: depends on libde265 (HEVC decoder) only.
# All encoders (libaom, x265, dav1d, kvazaar, svt-av1) are disabled
# explicitly in build-libheif.sh because the cmake auto-detection
# would happily pick up host libs otherwise.
{ mkDep, libde265, libjpeg-turbo, libpng }:
mkDep {
  name = "libheif";
  deps = [ libde265 libjpeg-turbo libpng ];
}
