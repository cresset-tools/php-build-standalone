# libsodium bundled-dep derivation. Build commands live in
# build-libsodium.sh; this file just declares the derivation shape via
# mkDep. Consumed by PHP's sodium extension.
{ mkDep }:
mkDep {
  name = "libsodium";
}
