{ pkgs, sources, toolchain, openssl, zlib, nghttp2 }:
let mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in mkDep {
  name = "libcurl";
  buildScript = ./build-libcurl.sh;
  deps = [ openssl zlib nghttp2 ];
}
