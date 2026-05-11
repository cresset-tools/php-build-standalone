# igbinary — fast binary serializer for PHP, used as a serializer backend
# by phpredis (Redis::OPT_SERIALIZER) and Memcached among others. Pure C,
# no external C-library; built via the just-installed bin/phpize. Mirrors
# redis.nix.
#
# `igbinarySpec` is the value from sources.igbinaryVersions.<series> —
# parallel to xdebugSpec / imagickSpec / redisSpec.
{ mkDep, pkgs, php, igbinarySpec }:
mkDep {
  name = "igbinary";
  version = igbinarySpec.version;
  src = pkgs.fetchurl { inherit (igbinarySpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
