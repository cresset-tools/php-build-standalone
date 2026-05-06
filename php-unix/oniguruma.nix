# Oniguruma bundled-dep derivation. Provides libonig.so for PHP's
# mbstring extension (mb_ereg / mb_split regex functions). No runtime
# deps beyond libc. Build commands live in build-oniguruma.sh.
#
# Note: upstream's tarball extracts as onig-<version>/, but our dep key
# (and PHP-side flag convention) is "oniguruma". The build script
# bridges the naming mismatch.
{ pkgs, sources, toolchain }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "oniguruma";
  buildScript = ./build-oniguruma.sh;
}
