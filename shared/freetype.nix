# FreeType bundled-dep derivation. Depends on zlib (compressed font tables,
# e.g. PCF/BDF gzipped sources) and bzip2 (bzip2-compressed PCF font files).
# Used by PHP's gd extension for TrueType text rendering (imagettftext et al).
#
# --with-zlib=yes / --with-bzip2=yes are autodetected via the -I/-L
# flags mkDep appends for each dep. We disable libpng (PNG-embedded
# color fonts — emoji), harfbuzz (would create a circular dep:
# HarfBuzz uses FreeType, FreeType can use HarfBuzz for OT auto-hinting),
# and brotli (WOFF2 web fonts; not needed server-side). bin/ is dropped
# because freetype-config bakes in the build-time prefix.
{ mkDep, zlib, bzip2 }:
mkDep {
  name = "freetype";
  builder = "autotools";
  deps = [ zlib bzip2 ];
  configureFlags = [
    "--with-zlib=yes"
    "--with-bzip2=yes"
    "--with-png=no"
    "--with-harfbuzz=no"
    "--with-brotli=no"
  ];
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libfreetype" ];
}
