# bzip2 bundled-dep derivation. Build commands live in build-bzip2.sh;
# the platform-specific shared-lib build snippet is selected here on
# the Nix side and threaded into the script via $PBS_BZIP2_SHARED_BUILD.
{ mkDep, pkgs }:
let inherit (pkgs) stdenv; in
mkDep {
  name = "bzip2";
  extraEnv = {
    PBS_BZIP2_SHARED_BUILD =
      if stdenv.isDarwin
      then ./build-bzip2-shared-darwin.sh
      else ./build-bzip2-shared-linux.sh;
  };
}
