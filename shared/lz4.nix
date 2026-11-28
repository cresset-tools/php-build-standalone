# lz4 bundled-dep derivation (liblz4). Consumed by the redis PECL
# extension's lz4 compressor. Plain Makefile, no configure, so it goes
# through build-lz4.sh rather than mkDep's autotools template.
{ mkDep }:
mkDep {
  name = "lz4";
}
