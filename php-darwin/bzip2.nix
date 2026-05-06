{ pkgs, sources, toolchain }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "bzip2";
  buildScript = ./build-bzip2.sh;
}
