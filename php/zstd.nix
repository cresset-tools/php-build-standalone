# zstd — PHP extension exposing zstd_compress() / zstd_uncompress(). These
# are the functions colinmollenhour/cache-backend-redis calls when
# Magento's redis cache or session config sets compression_lib = zstd.
# Built via the just-installed bin/phpize, mirroring ev.nix.
#
# Depends only on `php`. The compressor is vendored in the source
# tarball and compiled in-tree, so there is no bundled C-library input
# and no store/ closure entry beyond PHP's own. That ties the library
# version to the extension release; a shared store path only pays off
# once a second consumer (phpredis's own compression) links it.
#
# `zstdSpec` is the value from sources.zstdVersions.<series>.
{ mkDep, pkgs, php, zstdSpec }:
mkDep {
  name = "zstd";
  buildScript = ./build-zstd.sh;
  version = zstdSpec.version;
  src = pkgs.fetchurl { inherit (zstdSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
