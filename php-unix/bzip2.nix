# bzip2 bundled-dep derivation. Build commands live in build-bzip2.sh; this
# file just declares the derivation shape via mkDep.
{ mkDep }:
mkDep {
  name = "bzip2";
}
