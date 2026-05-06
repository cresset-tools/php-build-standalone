# sqlite bundled-dep derivation. Provides libsqlite3.so + headers + .pc
# for PHP's pdo_sqlite (and ext/sqlite3) extensions. Leaf node in the dep
# graph: links only against libm/libc.
{ pkgs, sources, toolchain }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "sqlite";
  buildScript = ./build-sqlite.sh;
}
