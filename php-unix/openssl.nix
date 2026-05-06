# OpenSSL bundled-dep derivation. Depends on zlib (compression support
# is wired into TLS record layer; PHP's openssl extension expects it).
# OpenSSL's Configure is a perl script; perl needs to be in PATH.
{ mkDep, pkgs, zlib }:
let inherit (pkgs) stdenv; in
mkDep {
  name = "openssl";
  deps = [ zlib ];
  extraInputs = [ pkgs.perl ];
  extraEnv = {
    # OpenSSL's Configure takes its own target name (not an autotools
    # triple). Picked here so the bash script stays OS-agnostic.
    PBS_OPENSSL_TARGET = if stdenv.isDarwin then "darwin64-arm64-cc" else "linux-x86_64";
  };
}
