# msgpack — MessagePack codec for PHP, used as an alternative serializer
# backend by phpredis / Memcached. Pure C, no external C-library; built
# via the just-installed bin/phpize. Mirrors redis.nix / igbinary.nix.
#
# `msgpackSpec` is the value from sources.msgpackVersions.<series>.
{ mkDep, pkgs, php, msgpackSpec }:
mkDep {
  name = "msgpack";
  version = msgpackSpec.version;
  src = pkgs.fetchurl { inherit (msgpackSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
