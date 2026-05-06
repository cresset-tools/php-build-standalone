# zlib bundled-dep derivation. Build commands live in build-zlib.sh; this
# file just declares the derivation shape via mkDep.
{ mkDep }:
mkDep {
  name = "zlib";
}
