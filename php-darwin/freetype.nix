{ pkgs, sources, toolchain, zlib, bzip2 }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "freetype";
  buildScript = ./build-freetype.sh;
  deps = [ zlib bzip2 ];
}
