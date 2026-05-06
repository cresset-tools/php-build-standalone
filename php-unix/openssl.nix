# OpenSSL bundled-dep derivation. Depends on zlib (compression support
# is wired into TLS record layer; PHP's openssl extension expects it).
# OpenSSL's Configure is a perl script; perl needs to be in PATH.
{ mkDep, pkgs, zlib }:
mkDep {
  name = "openssl";
  deps = [ zlib ];
  extraInputs = [ pkgs.perl ];
}
