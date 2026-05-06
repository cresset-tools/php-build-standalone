# PHP itself. Built last after every bundled dep, against the dep tree
# rather than against host system libraries.
#
# We pass the prepare-php.sh path through extraEnv so build-php.sh can
# source it before configure runs (configure consumes scripts/phpize.in
# and scripts/php-config.in as inputs, so the patches must land first).
#
# `phpSpec` is the value from sources.phpVersions.<major.minor> — it carries
# version, url, and sha256. Keeping it as a separate arg (not sourced from
# sources.php) is what lets flake.nix fan out multiple PHP versions without
# duplicating this derivation.
{ pkgs, sources, toolchain, phpSpec
, zlib, openssl, libxml2, sqlite, oniguruma, libsodium, bzip2
, libpng, libjpeg-turbo, libwebp, freetype
, nghttp2, libzip, icu, libcurl, ncurses, libedit
}:
let
  mkDep = import ./mkDep.nix { inherit pkgs sources toolchain; };
in
mkDep {
  name = "php";
  version = phpSpec.version;
  src = pkgs.fetchurl { inherit (phpSpec) url sha256; };
  buildScript = ./build-php.sh;
  deps = [
    zlib openssl libxml2 sqlite oniguruma libsodium bzip2
    libpng libjpeg-turbo libwebp freetype
    nghttp2 libzip icu libcurl ncurses libedit
  ];
  extraEnv = {
    PBS_PHP_PREPARE_SCRIPT = ./prepare-php.sh;
    PBS_PHP_PATCHES_DIR = ./patches;
    # Phase B will use this for per-version patch dispatch in build-php.sh.
    PBS_VER_PHP_MAJORMINOR = pkgs.lib.versions.majorMinor phpSpec.version;
  };
  # PHP's buildconf/configure pipeline needs bison + re2c (both already in
  # toolchain.nix, listed here as defense-in-depth in case the toolchain
  # ever loses them).
  extraInputs = with pkgs; [ bison re2c ];
}
