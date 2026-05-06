# ncurses bundled-dep derivation. Provides libncursesw.so + libtinfow.so
# as the terminfo backend for libedit. Leaf node: no dep inputs beyond libc.
# Build commands live in build-ncurses.sh.
{ mkDep }:
mkDep {
  name = "ncurses";
}
