# OpenSSL bundled-dep derivation. Depends on zlib (compression support
# is wired into TLS record layer; PHP's openssl extension expects it).
{ pkgs, sources, toolchain, zlib }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "openssl";
  buildScript = ./build-openssl.sh;
  deps = [ zlib ];
}
