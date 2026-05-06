# libzip bundled-dep derivation. Provides libzip.so + headers for PHP's
# zip extension (ZIP archive read/write). Depends on zlib (mandatory base
# deflate support), bzip2 (bzip2-compressed entries), and openssl (AES
# encryption per the modern .zip spec). lzma/zstd backends are disabled —
# the PBS bundle doesn't carry xz or zstd.
{ pkgs, sources, toolchain, zlib, bzip2, openssl }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "libzip";
  buildScript = ./build-libzip.sh;
  deps = [ zlib bzip2 openssl ];
}
