# libwebp bundled-dep derivation. Build commands live in
# build-libwebp.sh; this file just declares the derivation shape via
# mkDep. Consumed by PHP's gd extension for WebP encode/decode.
{ mkDep }:
mkDep {
  name = "libwebp";
}
