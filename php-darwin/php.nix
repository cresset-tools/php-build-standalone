# PHP itself, Darwin variant. Reuses the shared prepare-php.sh and patch
# directory from php-unix/ — both are platform-agnostic and the embedded
# pbs_relocate.h header switches on __APPLE__ at compile time.
{ pkgs, sources, toolchain, phpSpec
, zlib, openssl, libxml2, sqlite, oniguruma, libsodium, bzip2
, libpng, libjpeg-turbo, libwebp, freetype
, nghttp2, libzip, icu, libcurl, ncurses, libedit, libiconv
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
    nghttp2 libzip icu libcurl ncurses libedit libiconv
  ];
  extraEnv = {
    PBS_PHP_PREPARE_SCRIPT = ../php-unix/prepare-php.sh;
    PBS_PHP_PATCHES_DIR = ../php-unix/patches;
    PBS_VER_PHP_MAJORMINOR = pkgs.lib.versions.majorMinor phpSpec.version;
    # nixpkgs darwin.libresolv provides build-time -L/<store>/lib +
    # libresolv.dylib for ld to satisfy `-lresolv` (used by ext/standard/dns).
    # build-php.sh rewrites the resulting LC_LOAD_DYLIB to
    # /usr/lib/libresolv.9.dylib post-link so the tarball references the
    # consumer's system libresolv instead of /nix/store.
    PBS_DEP_LIBRESOLV_DIR = pkgs.darwin.libresolv;
    # The matching dev output ships <resolv.h>, <arpa/nameser.h>,
    # <dns.h>, etc. — the legacy networking headers stripped from
    # nixpkgs's apple-sdk derivations. Used at compile time so PHP's
    # ext/standard/dns.c can find them without us having to copy from
    # the host CLT SDK at build time (machine-dependent + non-reproducible).
    PBS_DEP_LIBRESOLV_INCLUDE = pkgs.lib.getInclude pkgs.darwin.libresolv;
  };
  extraInputs = with pkgs; [ bison re2c ];
}
