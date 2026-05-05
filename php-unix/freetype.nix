# FreeType bundled-dep derivation. Depends on zlib (compressed font tables,
# e.g. PCF/BDF gzipped sources) and bzip2 (bzip2-compressed PCF font files).
# Used by PHP's gd extension for TrueType text rendering (imagettftext et al).
{ pkgs, sources, zlib, bzip2 }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources; };
in
mkDep {
  name = "freetype";
  buildScript = ./build-freetype.sh;
  deps = [ zlib bzip2 ];
}
