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
#
# `libiconv` is Darwin-only (apple-sdk strips legacy libiconv headers). On
# Linux glibc provides iconv directly, so libiconv defaults to null and is
# absent from the deps list.
{ mkDep, pkgs, phpSpec
, zlib, openssl, libxml2, libxslt, sqlite, oniguruma, libsodium, bzip2
, libpng, libjpeg-turbo, libwebp, freetype
, nghttp2, libzip, icu, libcurl, ncurses, libedit, libpq, libgmp
, libiconv ? null
}:
let
  inherit (pkgs) stdenv lib;
in
mkDep {
  name = "php";
  buildScript = ./build-php.sh;
  version = phpSpec.version;
  src = pkgs.fetchurl { inherit (phpSpec) url sha256; };
  deps = [
    zlib openssl libxml2 libxslt sqlite oniguruma libsodium bzip2
    libpng libjpeg-turbo libwebp freetype
    nghttp2 libzip icu libcurl ncurses libedit libpq libgmp
  ] ++ lib.optionals stdenv.isDarwin [ libiconv ];
  extraEnv = {
    PBS_PHP_PREPARE_SCRIPT = ./prepare-php.sh;
    PBS_PHP_PATCHES_DIR = ./patches;
    # Consumed by prepare-php.sh to dispatch range-suffixed patches —
    # files in patches/ named NNNN-name@LO-HI.patch, where LO and HI are
    # major-minor numbers (e.g. 81 = PHP 8.1) bounding the version range
    # the patch applies to. See prepare-php.sh for the full convention.
    PBS_VER_PHP_MAJORMINOR = lib.versions.majorMinor phpSpec.version;

    # Platform-divergent build-php.sh snippets, picked here on the Nix
    # side so the script itself stays OS-agnostic.
    PBS_PHP_PRE_CONFIGURE = if stdenv.isDarwin
      then ./build-php-pre-configure-darwin.sh
      else ./build-php-pre-configure-linux.sh;
    PBS_PHP_POST_INSTALL = if stdenv.isDarwin
      then ./build-php-post-install-darwin.sh
      else ./build-php-post-install-noop.sh;
    PBS_PHP_AUDIT_EXTRA = if stdenv.isDarwin
      then ./build-php-audit-extra-noop.sh
      else ./build-php-audit-extra-linux.sh;
    # Linux's iconv comes from glibc — no path. Darwin uses our bundled
    # GNU libiconv since apple-sdk strips the system iconv headers.
    PBS_PHP_ICONV_ARG = if stdenv.isDarwin
      then "--with-iconv=shared,${libiconv}"
      else "--with-iconv=shared";
    # Linux: glibc's libintl (in libc itself), but PHP's ext/gettext
    # config.m4 only looks under /usr/include and /usr/local/include for
    # libintl.h, never consulting the sysroot. We point it at the CentOS 7
    # sysroot's /usr explicitly. Darwin: Apple's libc ships only stub gettext
    # symbols and no real translation lookup; until we bundle GNU gettext,
    # the Darwin leg opts out entirely.
    PBS_PHP_GETTEXT_ARG = if stdenv.isDarwin
      then "--without-gettext"
      else "--with-gettext=shared,__PBS_SYSROOT__/usr";
  } // lib.optionalAttrs stdenv.isDarwin {
    # nixpkgs darwin.libresolv provides build-time -L/<store>/lib +
    # libresolv.dylib for ld to satisfy `-lresolv` (used by ext/standard/dns).
    # build-php-post-install-darwin.sh rewrites the resulting LC_LOAD_DYLIB
    # to /usr/lib/libresolv.9.dylib so the tarball references the consumer's
    # system libresolv instead of /nix/store.
    PBS_DEP_LIBRESOLV_DIR = pkgs.darwin.libresolv;
    # The matching dev output ships <resolv.h>, <arpa/nameser.h>, <dns.h>,
    # etc. — the legacy networking headers stripped from nixpkgs's
    # apple-sdk derivations. Used at compile time so PHP's
    # ext/standard/dns.c can find them without us having to copy from
    # the host CLT SDK at build time (machine-dependent + non-reproducible).
    PBS_DEP_LIBRESOLV_INCLUDE = lib.getInclude pkgs.darwin.libresolv;
  };
  # PHP's buildconf/configure pipeline needs bison + re2c (both already in
  # the toolchain pkg list; defense-in-depth listing here).
  extraInputs = with pkgs; [ bison re2c ];
}
