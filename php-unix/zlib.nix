# zlib bundled-dep derivation. Built via mkDep's autotools template.
#
# zlib's configure is hand-rolled (not autoconf): it doesn't accept
# --disable-static/--enable-shared, only --shared. configureDefaults =
# false suppresses the template's standard pair, and we pass --shared
# explicitly. zlib otherwise installs both libz.a and libz.so/dylib;
# we drop the static archive in postInstallCleanup since the bundle
# ships shared-only.
{ mkDep }:
mkDep {
  name = "zlib";
  builder = "autotools";
  configureDefaults = false;
  configureFlags = [ "--shared" ];
  postInstallCleanup = [ "lib/libz.a" ];
  auditLibs = [ "libz" ];
}
