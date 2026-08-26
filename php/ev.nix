# ev — PECL extension binding libev to PHP. ReactPHP selects it as
# `ExtEvLoop`. Built via the just-installed bin/phpize, mirroring
# redis.nix.
#
# Depends only on `php`. libev itself is vendored in the PECL source
# (ev-<version>/libev/) and compiled in-tree by config.m4's
# `PHP_ADD_BUILD_DIR($ext_builddir/libev)`, so unlike event.nix and
# uv.nix there is no bundled C-library input — and correspondingly no
# store/ closure entry beyond PHP's own.
#
# ev.so carries an undefined reference to `socket_ce` (see
# build-ev.sh), so its conf.d fragment loads at prefix 40, after
# ext/sockets' own 20-sockets.ini. flake.nix sets that.
#
# `evSpec` is the value from sources.evVersions.<series> — parallel to
# redisSpec / xdebugSpec.
{ mkDep, pkgs, php, evSpec }:
mkDep {
  name = "ev";
  buildScript = ./build-ev.sh;
  version = evSpec.version;
  src = pkgs.fetchurl { inherit (evSpec) url sha256; };
  deps = [ php ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
