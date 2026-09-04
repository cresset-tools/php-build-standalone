# excimer — PECL extension providing a low-overhead sampling profiler.
# Wikimedia's; the production-safe complement to xdebug (step debugging),
# pcov (coverage) and spx (flame-graph profiling), all of which cost too
# much to leave enabled under real traffic.
#
# Depends only on `php`. The timer backend comes from libc — POSIX
# interval timers (librt's timer_create) on Linux, kqueue on Darwin — so
# there is no bundled C-library input and the manifest closure is empty,
# the same shape as redis.nix and pcov.nix.
#
# `excimerSpec` is the value from sources.excimerVersions.<series>.
{ mkDep, pkgs, php, excimerSpec }:
mkDep {
  name = "excimer";
  buildScript = ./build-excimer.sh;
  version = excimerSpec.version;
  src = pkgs.fetchurl { inherit (excimerSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
