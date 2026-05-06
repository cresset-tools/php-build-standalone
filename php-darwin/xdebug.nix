{ pkgs, sources, toolchain, php, xdebugSpec }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "xdebug";
  version = xdebugSpec.version;
  src = pkgs.fetchurl { inherit (xdebugSpec) url sha256; };
  buildScript = ./build-xdebug.sh;
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 ];
}
