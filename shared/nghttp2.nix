# nghttp2 bundled-dep derivation. Consumed (transitively) by PHP's
# curl extension via libcurl, which links against libnghttp2 for HTTP/2.
#
# --enable-lib-only skips the nghttp / nghttpd / h2load C++ apps, which
# would otherwise pull in libxml2, jemalloc, jansson, libev, libevent,
# etc. as deps. We only need the C library.
{ mkDep }:
mkDep {
  name = "nghttp2";
  builder = "autotools";
  configureFlags = [ "--enable-lib-only" ];
  postInstallCleanup = [ "bin" ];
  auditLibs = [ "libnghttp2" ];
}
