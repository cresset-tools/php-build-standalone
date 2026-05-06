{ pkgs, sources, toolchain, zlib, bzip2, openssl }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "libzip";
  buildScript = ./build-libzip.sh;
  deps = [ zlib bzip2 openssl ];
}
