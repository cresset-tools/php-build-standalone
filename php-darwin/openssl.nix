{ pkgs, sources, toolchain, zlib }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "openssl";
  buildScript = ./build-openssl.sh;
  deps = [ zlib ];
  # OpenSSL's Configure is a perl script; perl needs to be in PATH.
  extraInputs = [ pkgs.perl ];
}
