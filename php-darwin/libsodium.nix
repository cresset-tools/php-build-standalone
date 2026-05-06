{ pkgs, sources, toolchain }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "libsodium";
  buildScript = ./build-libsodium.sh;
}
