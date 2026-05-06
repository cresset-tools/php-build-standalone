# libxml2 bundled-dep derivation. Depends on zlib for compressed-xml
# support (PHP's xml ext expects this codepath to exist).
{ pkgs, sources, toolchain, zlib }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "libxml2";
  buildScript = ./build-libxml2.sh;
  deps = [ zlib ];
}
