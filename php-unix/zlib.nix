# zlib bundled-dep derivation. Build commands live in build-zlib.sh; this
# file just declares the derivation shape via mkDep.
{ pkgs, sources }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources; };
in
mkDep {
  name = "zlib";
  buildScript = ./build-zlib.sh;
}
