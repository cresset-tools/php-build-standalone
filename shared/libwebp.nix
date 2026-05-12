# libwebp bundled-dep derivation. Built via mkDep's autotools template.
#
# We disable libwebp's libpng/libjpeg/libtiff/libgif/libwic bridges:
# they're used only by libwebp's own cwebp/dwebp CLIs to read source
# images. PHP's gd does its own format conversions and uses libwebp
# purely for raw WebP encode/decode, so dropping the bridges keeps
# libpng/libjpeg out of libwebp's link line.
{ mkDep }:
mkDep {
  name = "libwebp";
  builder = "autotools";
  configureFlags = [
    "--disable-png"
    "--disable-jpeg"
    "--disable-tiff"
    "--disable-gif"
    "--disable-wic"
  ];
  postInstallCleanup = [ "bin" "share" ];
  auditLibs = [ "libwebp" ];
}
