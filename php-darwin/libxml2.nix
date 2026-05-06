{ pkgs, sources, toolchain, zlib }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "libxml2";
  buildScript = ./build-libxml2.sh;
  deps = [ zlib ];
}
