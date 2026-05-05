# PHP itself. Built last after every bundled dep, against the dep tree
# rather than against host system libraries.
#
# We pass the prepare-php.sh path through extraEnv so build-php.sh can
# source it before configure runs (configure consumes scripts/phpize.in
# and scripts/php-config.in as inputs, so the patches must land first).
{ pkgs, sources
, zlib, openssl, libxml2, sqlite, oniguruma, libsodium, bzip2
, libpng, libjpeg-turbo, libwebp, freetype
, nghttp2, libzip, icu, libcurl
}:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources; };
in
mkDep {
  name = "php";
  buildScript = ./build-php.sh;
  deps = [
    zlib openssl libxml2 sqlite oniguruma libsodium bzip2
    libpng libjpeg-turbo libwebp freetype
    nghttp2 libzip icu libcurl
  ];
  extraEnv = {
    PBS_PHP_PREPARE_SCRIPT = ./prepare-php.sh;
    PBS_PHP_PATCHES_DIR = ./patches;
  };
  # PHP's buildconf/configure pipeline needs bison + re2c (both already in
  # toolchain.nix, listed here as defense-in-depth in case the toolchain
  # ever loses them).
  extraInputs = with pkgs; [ bison re2c ];
}
