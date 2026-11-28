# lz4 — PHP extension exposing lz4_compress() / lz4_uncompress(). These
# are the functions colinmollenhour/cache-backend-redis calls when
# Magento's redis cache or session config sets compression_lib = lz4.
# Built via the just-installed bin/phpize, mirroring ev.nix.
#
# Depends only on `php`. The compressor is vendored in the source
# tarball and compiled in-tree, so there is no bundled C-library input
# and no store/ closure entry beyond PHP's own. That ties the library
# version to the extension release; a shared store path only pays off
# once a second consumer (phpredis's own compression) links it.
#
# `lz4Spec` is the value from sources.lz4Versions.<series>.
{ mkDep, pkgs, php, lz4Spec }:
mkDep {
  name = "lz4";
  buildScript = ./build-lz4.sh;
  version = lz4Spec.version;
  src = pkgs.fetchurl { inherit (lz4Spec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
