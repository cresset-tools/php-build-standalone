# libcurl bundled-dep derivation. Depends on:
#   - openssl  — TLS backend (CURLOPT_SSL_VERIFYPEER etc)
#   - zlib     — gzip/deflate Content-Encoding
#   - nghttp2  — HTTP/2 support
# Used by PHP's curl extension.
{ mkDep, openssl, zlib, nghttp2 }:
mkDep {
  name = "libcurl";
  deps = [ openssl zlib nghttp2 ];
}
