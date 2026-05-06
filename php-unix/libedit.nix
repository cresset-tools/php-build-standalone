# libedit bundled-dep derivation. Provides libedit.so for PHP's ext/readline
# extension (the interactive php -a shell). Depends on ncurses (specifically
# libtinfow) for terminal capability and terminfo lookups.
#
# We use libedit rather than GNU readline because readline is GPL-licensed.
# Distributing a PHP binary linked against readline would impose GPL terms
# on the combined work. libedit uses the BSD license. Same choice as Debian,
# Homebrew, and FreeBSD's PHP packages.
{ pkgs, sources, toolchain, ncurses }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "libedit";
  buildScript = ./build-libedit.sh;
  deps = [ ncurses ];
}
