# Oniguruma bundled-dep derivation. Provides libonig.so/.dylib for
# PHP's mbstring extension (mb_ereg / mb_split regex functions).
#
# Tarball-name quirk: upstream's tarball extracts to onig-<version>/,
# but our internal dep key (and PHP's --with-onig flag convention) is
# "oniguruma" — hence the srcSubdir override. bin/onig-config is a
# config helper with the build-time prefix baked in; PHP uses the .pc
# file instead, so we drop bin/.
{ mkDep }:
mkDep {
  name = "oniguruma";
  builder = "autotools";
  srcSubdir = v: "onig-${v}";
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libonig" ];
}
