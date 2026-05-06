{ pkgs, sources, toolchain }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "nghttp2";
  buildScript = ./build-nghttp2.sh;
}
