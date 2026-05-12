# libpng bundled-dep derivation. Depends on zlib (PNG's DEFLATE-based
# IDAT compression is implemented via libz; libpng won't build without it).
# Consumed by PHP's gd extension.
#
# --with-zlib-prefix is set explicitly: mkDep already appends -I/-L
# from the zlib dep, but libpng's configure also runs an explicit
# link-test using this prefix var, so set it to be safe. We drop bin/
# because libpng-config and png-fix-itxt embed the build-time prefix.
{ mkDep, zlib }:
mkDep {
  name = "libpng";
  builder = "autotools";
  deps = [ zlib ];
  configureFlags = [ ''--with-zlib-prefix="$PBS_DEP_ZLIB"'' ];
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libpng16" ];
}
