{ pkgs, sources, toolchain, ncurses }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "libedit";
  buildScript = ./build-libedit.sh;
  deps = [ ncurses ];
}
