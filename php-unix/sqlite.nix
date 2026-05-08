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
#
# LD: autosetup's `cc-check-tools ld ar` step hard-errors if no `ld`
# binary is reachable. The Linux toolchain ships `ld` (a symlink to
# lld), but the Darwin toolchain doesn't — clang invokes the system
# linker directly via its driver. Setting LD=$CC satisfies the
# configure-time probe on both platforms; sqlite's Makefile.in actually
# uses CC for the link step, so the value of LD is purely cosmetic at
# build time.
{ mkDep }:
mkDep {
  name = "sqlite";
  builder = "autotools";
  srcGlob = "sqlite-autoconf-*";
  extraEnv = {
    LD = "$CC";
  };
  configureFlags = [
    "--disable-readline"
    # autosetup defaults to NO SONAME on libsqlite3.so. Without an
    # SONAME the linker stamps consumers (PHP's sqlite3.so / pdo_sqlite.so)
    # with DT_NEEDED=libsqlite3.so (the file basename), and finalize's
    # soname→storeName map has no entry for the unversioned basename —
    # the RPATH audit fails. "legacy" restores the historical
    # libsqlite3.so.0 SONAME that autotools 3.47.x emitted by default.
    "--soname=legacy"
  ];
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libsqlite3" ];
}
