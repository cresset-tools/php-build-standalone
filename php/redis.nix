# redis (phpredis) — PECL extension binding hiredis-style protocol handling
# to PHP. Built via the just-installed bin/phpize, mirroring xdebug.nix.
#
# phpredis speaks the redis wire protocol itself; the inputs beyond `php`
# are the zstd and lz4 compressors (Redis::COMPRESSION_ZSTD / _LZ4), linked
# against the bundled libzstd / liblz4, which land in the closure.
#
# Serializer backends stay off. igbinary in particular makes redis.so
# declare ZEND_MOD_REQUIRED("igbinary"): PHP then refuses to load redis
# without igbinary, and bougie releases that predate the manifest's
# `requires` field would install redis alone and leave it broken. msgpack
# has the same shape; lzf is simply not wanted alongside zstd/lz4.
#
# `redisSpec` is the value from sources.redisVersions.<series> — parallel
# to xdebugSpec / imagickSpec. Kept as a separate arg so flake.nix can
# pair different redis releases with different PHP variants in the future.
{ mkDep, pkgs, php, redisSpec, zstd, lz4 }:
mkDep {
  name = "redis";
  buildScript = ./build-redis.sh;
  version = redisSpec.version;
  src = pkgs.fetchurl { inherit (redisSpec) url sha256; };
  deps = [ php zstd lz4 ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
