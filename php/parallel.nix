# parallel — PECL extension providing userland threads (parallel\Runtime,
# Future, Channel, Events). Thread-safe PHP only: config.m4 aborts on an
# NTS interpreter, so flake.nix builds this for the zts flavor alone
# (sources.ztsOnlyExtensions).
#
# Depends only on `php`. Threads come from libc's pthreads, so there is no
# bundled C-library input and the manifest closure is empty, the same shape
# as excimer.nix and pcov.nix.
#
# `parallelSpec` is the value from sources.parallelVersions.<series>.
{ mkDep, pkgs, php, parallelSpec }:
mkDep {
  name = "parallel";
  buildScript = ./build-parallel.sh;
  version = parallelSpec.version;
  src = pkgs.fetchurl { inherit (parallelSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
  # Unreleased upstream fixes, two of them PHP 8.6 compatibility. Applied
  # on every minor so all of them build from one source. See the patch
  # header for the upstream PRs.
  extraEnv = { PBS_PARALLEL_FIXES_PATCH = ./parallel-fixes.patch; };
}
