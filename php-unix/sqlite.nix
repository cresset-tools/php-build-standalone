# sqlite bundled-dep derivation. Provides libsqlite3.so + headers + .pc
# for PHP's pdo_sqlite (and ext/sqlite3) extensions. Leaf node in the dep
# graph: links only against libm/libc.
#
# srcGlob: the autoconf tarball extracts to sqlite-autoconf-<numeric>/,
# where the numeric form is e.g. 3470200 for 3.47.2 — not derivable
# from sources.sqlite.version, so we discover the directory via shell
# glob.
#
# --disable-readline / --disable-editline: avoid configure auto-picking
# up a host readline/editline (which would add a DT_NEEDED for
# libreadline that our toolchain wouldn't carry).
# --disable-tcl: harmless self-documenting flag (sqlite's TCL probe is
# gated by --with-tcl=DIR, so this is a no-op but spells the intent).
# bin/ is dropped because PHP doesn't ship the sqlite3 CLI.
{ mkDep }:
mkDep {
  name = "sqlite";
  builder = "autotools";
  srcGlob = "sqlite-autoconf-*";
  configureFlags = [
    "--disable-readline"
    "--disable-tcl"
    "--disable-editline"
  ];
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libsqlite3" ];
}
