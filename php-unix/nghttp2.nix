# nghttp2 bundled-dep derivation. Build commands live in build-nghttp2.sh;
# this file just declares the derivation shape via mkDep. Consumed
# (transitively) by PHP's curl extension via libcurl, which links against
# libnghttp2.so for HTTP/2 support.
{ pkgs, sources }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources; };
in
mkDep {
  name = "nghttp2";
  buildScript = ./build-nghttp2.sh;
}
