{ pkgs, sources, toolchain }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "libjpeg-turbo";
  buildScript = ./build-libjpeg-turbo.sh;
}
