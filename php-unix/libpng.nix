# libpng bundled-dep derivation. Depends on zlib (PNG's DEFLATE-based
# IDAT compression is implemented via libz; libpng won't build without it).
# Consumed by PHP's gd extension.
{ pkgs, sources, zlib }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources; };
in
mkDep {
  name = "libpng";
  buildScript = ./build-libpng.sh;
  deps = [ zlib ];
}
