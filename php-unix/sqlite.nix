# sqlite bundled-dep derivation. Provides libsqlite3.so + headers + .pc
# for PHP's pdo_sqlite (and ext/sqlite3) extensions. Leaf node in the dep
# graph: links only against libm/libc.
#
# srcGlob: the autoconf tarball extracts to sqlite-autoconf-<numeric>/,
# where the numeric form is e.g. 3470200 for 3.47.2 — not derivable
# from sources.sqlite.version, so we discover the directory via shell
# glob.
#
# Configure: sqlite >= 3.49 ships an autosetup-based ./configure (not GNU
# autoconf). It rejects unknown options outright, so the older
# --disable-tcl / --disable-editline spellings now fail. In autosetup:
#   - tcl is opt-in only via --with-tcl=DIR, so omitting any flag is
#     correct (no auto-detection of a host TCL).
#   - editline is opt-in via --editline (default off), so we don't
#     need to disable it.
#   - readline is on-by-default and still uses --disable-readline.
# We pass only --disable-readline; bin/ is dropped because PHP doesn't
# ship the sqlite3 CLI.
{ mkDep }:
mkDep {
  name = "sqlite";
  builder = "autotools";
  srcGlob = "sqlite-autoconf-*";
  configureFlags = [
    "--disable-readline"
  ];
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libsqlite3" ];
}
