# ncurses bundled-dep derivation. Provides libncursesw + libtinfow as
# the terminfo backend for libedit. Leaf node: no dep inputs beyond libc.
{ mkDep, pkgs }:
let inherit (pkgs) stdenv; in
mkDep {
  name = "ncurses";
  extraEnv = {
    # Compat symlinks for the widec libs. Soversioning convention
    # differs by platform; the right snippet is selected here.
    PBS_NCURSES_SYMLINKS =
      if stdenv.isDarwin
      then ./build-ncurses-symlinks-darwin.sh
      else ./build-ncurses-symlinks-linux.sh;
  };
}
