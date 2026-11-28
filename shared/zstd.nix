# zstd bundled-dep derivation (libzstd). Consumed by the redis PECL
# extension's zstd compressor. Plain Makefile, no configure, so it goes
# through build-zstd.sh rather than mkDep's autotools template.
{ mkDep }:
mkDep {
  name = "zstd";
}
