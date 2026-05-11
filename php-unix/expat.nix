# expat bundled-dep derivation. Small streaming XML parser; required by
# libvips for ICC-profile / HEIF-metadata parsing. Autotools, no
# transitive deps. xmlwf (the validator CLI) is dropped — we don't ship
# it and it bakes the build-time prefix.
{ mkDep }:
mkDep {
  name = "expat";
  builder = "autotools";
  configureFlags = [
    "--without-docbook"
    "--without-examples"
    "--without-tests"
    "--without-xmlwf"
  ];
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libexpat" ];
}
