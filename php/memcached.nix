# memcached (php-memcached) — PECL extension binding libmemcached to PHP.
# Built via the just-installed bin/phpize, mirroring uv.nix.
#
# Depends on `php` (phpize/php-config/build files), `libmemcached` and
# `zlib`. zlib is required, not optional: config.m4 hard-errors without
# it (it backs Memcached::OPT_COMPRESSION alongside the vendored fastlz).
# It resolves to the same store path as the interpreter's own libz, so
# it adds nothing to the closure in practice.
#
# Feature set (see build-memcached.sh): session handler and JSON
# serializer on; igbinary / msgpack serializers, SASL and the protocol
# server off.
#
# `memcachedSpec` is the value from sources.memcachedVersions.<series>.
{ mkDep, pkgs, php, libmemcached, zlib, memcachedSpec }:
mkDep {
  name = "memcached";
  buildScript = ./build-memcached.sh;
  version = memcachedSpec.version;
  src = pkgs.fetchurl { inherit (memcachedSpec) url sha256; };
  deps = [ php libmemcached zlib ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
