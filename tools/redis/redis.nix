# Redis server bundle — redis-server, redis-cli, redis-benchmark, plus the
# redis-sentinel / redis-check-rdb / redis-check-aof symlinks the upstream
# install target lays down.
#
# Built dynamically linked against PBS's bundled OpenSSL (the only external
# C library Redis needs — jemalloc, hiredis, linenoise, lua, hdr_histogram,
# fast_float, xxhash all live under deps/ and are statically linked in by
# Redis's own Makefile). Tree is relocatable via $ORIGIN-relative RPATHs;
# the same pattern the PHP and MariaDB bundles use.
#
# `redisSpec` is sources.redis — kept as a separate arg so flake.nix can
# pin alternate Redis versions in the future without duplicating this
# derivation. Distinct from sources.redisVersions, which is the version
# map for the phpredis PECL extension (php/redis.nix).
{ mkDep, pkgs, redisSpec, openssl }:
mkDep {
  name = "redis";
  buildScript = ./build-redis.sh;
  version = redisSpec.version;
  src = pkgs.fetchurl { inherit (redisSpec) url sha256; };
  deps = [ openssl ];
  # Redis's Makefile build needs no autotools / cmake / meson. The only
  # extra build-time tool is pkg-config — Redis uses it to detect
  # libsystemd (which we explicitly skip via USE_SYSTEMD=no, but the
  # configure-time probe still invokes pkg-config and would emit a
  # "command not found" line otherwise).
  extraInputs = with pkgs; [ pkg-config ];
}
