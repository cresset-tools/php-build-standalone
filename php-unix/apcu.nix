# APCu — userspace shared-memory cache for PHP. Backend for Symfony's
# `cache.app`, Composer's class-loader cache, and a long tail of libraries
# that want process-survivable caching without external infrastructure.
# No external C-library — uses POSIX shm/mmap. Built via the just-installed
# bin/phpize, mirrors redis.nix.
#
# `apcuSpec` is the value from sources.apcuVersions.<series>.
{ mkDep, pkgs, php, apcuSpec }:
mkDep {
  name = "apcu";
  version = apcuSpec.version;
  src = pkgs.fetchurl { inherit (apcuSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
