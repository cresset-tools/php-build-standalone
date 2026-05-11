# xdebug — Zend extension for step-debugging, built via the just-installed
# bin/phpize. Headline use case for the whole project: this is the thing
# that static-php-cli can't do.
#
# Depends on `php` (the PHP derivation) so build-xdebug.sh can call
# $PBS_DEP_PHP/bin/phpize and have access to PHP's lib/php/build files.
# We do NOT inherit any of PHP's transitive deps here — phpize+php-config
# already report whatever include/lib paths the extension needs.
#
# `xdebugSpec` is the value from sources.xdebugVersions.<major.minor> —
# parallel to the phpSpec pattern in php.nix. Kept as a separate arg so
# flake.nix can pair different xdebug releases with different PHP variants.
{ mkDep, pkgs, php, xdebugSpec }:
mkDep {
  name = "xdebug";
  buildScript = ./build-xdebug.sh;
  version = xdebugSpec.version;
  src = pkgs.fetchurl { inherit (xdebugSpec) url sha256; };
  deps = [ php ];
  # phpize needs autoconf + autoheader at build time. They're already in
  # the toolchain pkg list, listed here as defense-in-depth and to
  # document the build-tool dependency at the call site.
  extraInputs = with pkgs; [ autoconf automake libtool m4 ];
}
