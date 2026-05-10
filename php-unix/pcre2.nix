# PCRE2 bundled-dep derivation. Required by glib (since glib 2.74,
# GRegex always links against an external pcre2; the in-tree copy was
# removed). Built with the 8-bit code-unit width — that's what glib
# expects, and what every distro packages. JIT compilation is enabled
# because both glib's GRegex and libvips's pattern matching benefit
# noticeably and the perf cost is borne only at first use.
#
# bin/pcre2-config / bin/pcre2grep / bin/pcre2test all bake the build-
# time prefix into pcre2-config; finalize-common.sh's text-detox would
# rewrite them but we don't need any of these binaries at runtime.
# .pc files (libpcre2-8.pc, libpcre2-posix.pc) are what glib's meson
# resolves against.
{ mkDep }:
mkDep {
  name = "pcre2";
  builder = "autotools";
  configureFlags = [
    "--enable-pcre2-8"
    "--disable-pcre2-16"
    "--disable-pcre2-32"
    "--enable-jit"
  ];
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libpcre2-8" ];
}
