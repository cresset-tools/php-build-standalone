# redis (phpredis) — PECL extension binding hiredis-style protocol handling
# to PHP. Built via the just-installed bin/phpize, mirroring xdebug.nix.
#
# Depends only on `php` (for phpize/php-config/build files). phpredis has
# no required external C library — it speaks the redis wire protocol
# directly. Optional integrations (igbinary, msgpack, lzf, zstd, lz4) are
# all left off; ship the default feature set and let users who need a
# specific serializer build their own variant.
#
# `redisSpec` is the value from sources.redisVersions.<series> — parallel
# to xdebugSpec / imagickSpec. Kept as a separate arg so flake.nix can
# pair different redis releases with different PHP variants in the future.
{ mkDep, pkgs, php, redisSpec }:
mkDep {
  name = "redis";
  buildScript = ./build-redis.sh;
  version = redisSpec.version;
  src = pkgs.fetchurl { inherit (redisSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
