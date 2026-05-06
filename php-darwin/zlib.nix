# Darwin zlib bundled-dep derivation.
{ pkgs, sources, toolchain }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "zlib";
  buildScript = ./build-zlib.sh;
}
