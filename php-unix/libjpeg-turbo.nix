# libjpeg-turbo bundled-dep derivation. Provides libjpeg.so + headers
# for PHP's gd extension (JPEG decode/encode). Build commands live in
# build-libjpeg-turbo.sh; this file just declares the derivation shape
# via mkDep. Leaf node in the dep graph: links only against libm/libc.
{ pkgs, sources }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources; };
in
mkDep {
  name = "libjpeg-turbo";
  buildScript = ./build-libjpeg-turbo.sh;
}
