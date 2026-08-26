# uv — PECL extension binding libuv to PHP. ReactPHP selects it as
# `ExtUvLoop`. Built via the just-installed bin/phpize, mirroring
# imagick.nix.
#
# Depends on `php` (phpize/php-config/build files) and `libuv`, which
# its config.m4 locates through pkg-config (`$PKG_CONFIG --exists
# libuv`) — see build-uv.sh.
#
# Unlike ev.so and event.so, uv.so needs no conf.d ordering against
# ext/sockets: upstream declares `socket_ce` weak and resolves it with
# DL_FETCH_SYMBOL against the already-loaded sockets module at MINIT, so
# the .so dlopens whether or not sockets is installed.
#
# `uvSpec` is the value from sources.uvVersions.<series>.
{ mkDep, pkgs, php, libuv, uvSpec }:
mkDep {
  name = "uv";
  buildScript = ./build-uv.sh;
  version = uvSpec.version;
  src = pkgs.fetchurl { inherit (uvSpec) url sha256; };
  deps = [ php libuv ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
