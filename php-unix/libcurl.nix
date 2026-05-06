# libcurl bundled-dep derivation. Depends on:
#   - openssl  — TLS backend (CURLOPT_SSL_VERIFYPEER etc)
#   - zlib     — gzip/deflate Content-Encoding
#   - nghttp2  — HTTP/2 support
# Used by PHP's curl extension.
{ pkgs, sources, toolchain, openssl, zlib, nghttp2 }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "libcurl";
  buildScript = ./build-libcurl.sh;
  deps = [ openssl zlib nghttp2 ];
}
