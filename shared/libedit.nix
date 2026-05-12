# libedit bundled-dep derivation. Provides libedit.so for PHP's ext/readline
# extension (the interactive php -a shell). Depends on ncurses (specifically
# libtinfow) for terminal capability and terminfo lookups.
#
# We use libedit rather than GNU readline because readline is GPL-licensed.
# Distributing a PHP binary linked against readline would impose GPL terms
# on the combined work. libedit uses the BSD license. Same choice as Debian,
# Homebrew, and FreeBSD's PHP packages.
#
# share/man holds editline(3,5,7) man pages that aren't useful in the
# portable tarball; bin/ is dropped for the standard reason.
{ mkDep, ncurses }:
mkDep {
  name = "libedit";
  builder = "autotools";
  deps = [ ncurses ];
  postInstallCleanup = [ "bin" "share/man" ];
  auditLibs = [ "libedit" ];
}
