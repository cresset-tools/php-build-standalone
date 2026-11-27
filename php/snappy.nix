# snappy — PHP extension exposing snappy_compress() / snappy_uncompress().
# These are the functions colinmollenhour/cache-backend-redis calls when
# Magento's redis cache or session config sets compression_lib = snappy.
# Built via the just-installed bin/phpize, mirroring ev.nix.
#
# Depends only on `php`. Google's snappy (C++) is vendored in the source
# tarball and compiled in-tree, with libstdc++ linked statically on Linux
# (see build-snappy.sh), so there is no bundled C-library input and no
# store/ closure entry beyond PHP's own.
#
# `snappySpec` is the value from sources.snappyVersions.<series>.
{ mkDep, pkgs, php, snappySpec }:
mkDep {
  name = "snappy";
  buildScript = ./build-snappy.sh;
  version = snappySpec.version;
  src = pkgs.fetchurl { inherit (snappySpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
