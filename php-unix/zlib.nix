# zlib bundled-dep derivation. Build commands live in build-zlib.sh; this
# file just declares the derivation shape via mkDep.
{ pkgs, sources, toolchain }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "zlib";
  buildScript = ./build-zlib.sh;
}
