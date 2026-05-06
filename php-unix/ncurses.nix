# ncurses bundled-dep derivation. Provides libncursesw.so + libtinfow.so
# as the terminfo backend for libedit. Leaf node: no dep inputs beyond libc.
# Build commands live in build-ncurses.sh.
{ pkgs, sources, toolchain }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "ncurses";
  buildScript = ./build-ncurses.sh;
}
