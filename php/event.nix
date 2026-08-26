# event — PECL extension binding libevent to PHP. ReactPHP selects it as
# `ExtEventLoop`. Built via the just-installed bin/phpize, mirroring
# imagick.nix.
#
# Depends on `php` (phpize/php-config/build files), `libevent`
# (libevent_core + libevent_extra + libevent_openssl) and `openssl`.
# openssl is listed explicitly rather than inherited through libevent
# because the extension's config.m4 runs PHP's own PHP_SETUP_OPENSSL
# macro, which needs openssl.pc reachable on PKG_CONFIG_PATH — see
# build-event.sh.
#
# event.so carries an undefined reference to `socket_ce` (see
# build-event.sh), so its conf.d fragment loads at prefix 40, after
# ext/sockets' own 20-sockets.ini. flake.nix sets that.
#
# `eventSpec` is the value from sources.eventVersions.<series>.
{ mkDep, pkgs, php, libevent, openssl, eventSpec }:
mkDep {
  name = "event";
  buildScript = ./build-event.sh;
  version = eventSpec.version;
  src = pkgs.fetchurl { inherit (eventSpec) url sha256; };
  deps = [ php libevent openssl ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
  # Runtime library path for bin/php itself, Linux only. `event` is the
  # only PECL extension here whose Makefile executes the interpreter
  # mid-build: configure regenerates php8/php_event.stub.php from its .in,
  # which fires PHP's gen_stub.php rule. On Linux the PHP dep is not
  # finalized at that point — its $ORIGIN RPATHs are written by
  # shared/finalize-linux.sh at tree time — so bin/php cannot resolve
  # libssl / libz / libxml2 on its own.
  #
  # mkDep's own PBS_DEPS_LDPATH only covers this derivation's *direct*
  # deps (php, libevent, openssl), which is short of what bin/php needs.
  # PHP's full bundled closure is exactly what passthru.transitiveBundledDeps
  # records, so hand that to build-event.sh to scope onto the make step.
  #
  # Darwin is deliberately excluded, for the same reason mkDep skips
  # PBS_DEPS_LDPATH there: exporting DYLD_LIBRARY_PATH across a whole
  # `make` diverts symbol resolution for any nixpkgs build-tool dylib that
  # shares a basename with one of our deps. It isn't needed either —
  # mkDep's Darwin postBuildHook rewrites each dep's LC_ID_DYLIB to its
  # absolute /nix/store path, so bin/php resolves them without help.
  # build-event.sh runs make unwrapped when this is empty.
  extraEnv = pkgs.lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
    PBS_PHP_LDPATH =
      pkgs.lib.makeLibraryPath ([ php ] ++ php.passthru.transitiveBundledDeps);
  };
}
