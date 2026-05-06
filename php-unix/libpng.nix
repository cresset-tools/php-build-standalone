# libpng bundled-dep derivation. Depends on zlib (PNG's DEFLATE-based
# IDAT compression is implemented via libz; libpng won't build without it).
# Consumed by PHP's gd extension.
{ mkDep, zlib }:
mkDep {
  name = "libpng";
  deps = [ zlib ];
}
