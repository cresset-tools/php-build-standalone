# bzip2 bundled-dep derivation. Build commands live in build-bzip2.sh; this
# file just declares the derivation shape via mkDep.
{ pkgs, sources, toolchain }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "bzip2";
  buildScript = ./build-bzip2.sh;
}
