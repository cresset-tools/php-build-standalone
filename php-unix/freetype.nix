# FreeType bundled-dep derivation. Depends on zlib (compressed font tables,
# e.g. PCF/BDF gzipped sources) and bzip2 (bzip2-compressed PCF font files).
# Used by PHP's gd extension for TrueType text rendering (imagettftext et al).
{ mkDep, zlib, bzip2 }:
mkDep {
  name = "freetype";
  deps = [ zlib bzip2 ];
}
