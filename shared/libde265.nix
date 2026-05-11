# libde265 bundled-dep derivation. HEVC/H.265 decoder, used as the
# decoder backend for libheif. Decode-only — we don't bundle x265
# (the encoder) because imagick's typical use is HEIC read, not
# write, and skipping x265 keeps the dep tree small + sidesteps the
# GPL-licensed encoder.
#
# `--disable-dec265 --disable-sherlock265` skip the example/test
# binaries (they bake build-time prefix into RPATH otherwise).
{ mkDep }:
mkDep {
  name = "libde265";
  builder = "autotools";
  configureFlags = [
    "--disable-dec265"
    "--disable-sherlock265"
    "--disable-encoder"
  ];
  postInstallCleanup = [ "bin" "share" ];
  auditLibs = [ "libde265" ];
}
