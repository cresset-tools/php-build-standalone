{ pkgs, sources, toolchain, zlib }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "libpng";
  buildScript = ./build-libpng.sh;
  deps = [ zlib ];
}
