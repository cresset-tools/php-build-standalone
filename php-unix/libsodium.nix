# libsodium bundled-dep derivation. Build commands live in
# build-libsodium.sh; this file just declares the derivation shape via
# mkDep. Consumed by PHP's sodium extension.
{ pkgs, sources, toolchain }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "libsodium";
  buildScript = ./build-libsodium.sh;
}
