# xdebug — Zend extension for step-debugging, built via the just-installed
# bin/phpize. Headline use case for the whole project: this is the thing
# that static-php-cli can't do.
#
# Depends on `php` (the PHP derivation) so build-xdebug.sh can call
# $PBS_DEP_PHP/bin/phpize and have access to PHP's lib/php/build files.
# We do NOT inherit any of PHP's transitive deps here — phpize+php-config
# already report whatever include/lib paths the extension needs.
{ pkgs, sources, toolchain, php }:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "xdebug";
  buildScript = ./build-xdebug.sh;
  deps = [ php ];
  # phpize needs autoconf + autoheader at build time. They're already in
  # toolchain.nix but listing here is defense-in-depth (and documents
  # the build-tool dependency at the call site).
  extraInputs = with pkgs; [ autoconf automake libtool m4 ];
}
