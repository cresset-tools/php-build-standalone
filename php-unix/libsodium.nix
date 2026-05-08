# libsodium bundled-dep derivation. Built via mkDep's autotools
# template — no special configure flags, no extra cleanup. PHP's
# sodium extension consumes libsodium for modern crypto primitives
# (Ed25519, X25519, ChaCha20-Poly1305, BLAKE2b, etc.).
{ mkDep }:
mkDep {
  name = "libsodium";
  builder = "autotools";
  auditLibs = [ "libsodium" ];
}
