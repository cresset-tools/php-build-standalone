# libwebp bundled-dep derivation. Build commands live in
# build-libwebp.sh; this file just declares the derivation shape via
# mkDep. Consumed by PHP's gd extension for WebP encode/decode.
{ pkgs, sources, toolchain }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "libwebp";
  buildScript = ./build-libwebp.sh;
}
