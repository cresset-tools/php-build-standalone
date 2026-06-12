# protobuf — native Protocol Buffers extension for PHP. The fast runtime
# behind google/protobuf and grpc/grpc PHP codegen, an order of magnitude
# faster than the pure-PHP fallback library. No external C-library — the
# upb runtime is vendored in the PECL source. Built via the just-installed
# bin/phpize, mirrors apcu.nix.
#
# `protobufSpec` is the value from sources.protobufVersions.<series>.
{ mkDep, pkgs, php, protobufSpec }:
mkDep {
  name = "protobuf";
  buildScript = ./build-protobuf.sh;
  version = protobufSpec.version;
  src = pkgs.fetchurl { inherit (protobufSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
