# pcov — code-coverage driver, an order of magnitude faster than xdebug's
# coverage mode and the standard pick when only coverage is needed (no step
# debugging, no var dumps, no tracing). Pure C, no external C-library;
# built via the just-installed bin/phpize, mirrors apcu.nix.
#
# `pcovSpec` is the value from sources.pcovVersions.<series>.
{ mkDep, pkgs, php, pcovSpec }:
mkDep {
  name = "pcov";
  buildScript = ./build-pcov.sh;
  version = pcovSpec.version;
  src = pkgs.fetchurl { inherit (pcovSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
