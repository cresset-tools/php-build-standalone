# opentelemetry — PECL extension exposing PHP's zend_observer fcall
# handlers to userland, which is what lets the open-telemetry/* Composer
# packages auto-instrument function calls instead of requiring manual
# span bookkeeping at every call site.
#
# Depends only on `php`. Upstream's config.m4 is the `pecl generate`
# skeleton with every dependency probe still commented out, so there is
# no bundled C-library input and the manifest closure is empty — the same
# shape as redis.nix and pcov.nix.
#
# This ships the observer API only. Span export is userland's job: over
# OTLP/HTTP+protobuf it pairs with the protobuf extension we already
# ship; OTLP/gRPC would additionally need ext-grpc, which we do not.
#
# `opentelemetrySpec` is the value from
# sources.opentelemetryVersions.<series>.
{ mkDep, pkgs, php, opentelemetrySpec }:
mkDep {
  name = "opentelemetry";
  buildScript = ./build-opentelemetry.sh;
  version = opentelemetrySpec.version;
  src = pkgs.fetchurl { inherit (opentelemetrySpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
