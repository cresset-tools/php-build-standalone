# OpenSSL bundled-dep derivation. Depends on zlib (compression support
# is wired into TLS record layer; PHP's openssl extension expects it).
{ pkgs, sources, zlib }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources; };
in
mkDep {
  name = "openssl";
  buildScript = ./build-openssl.sh;
  deps = [ zlib ];
}
