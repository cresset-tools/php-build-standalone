# Source-tarball manifest. Each entry becomes a fixed-output derivation
# in flake.nix via pkgs.fetchurl, so the sha256 is the load-bearing
# integrity check (Nix verifies it; mismatch fails the build).
#
# Replaces php-unix/downloads.yml — Nix is the only consumer, so YAML
# adds no value over a Nix attrset. backup_url support can be re-added
# via fetchurl's `urls` list if/when an upstream goes flaky.
#
# Structure:
#   - Flat attrs (zlib, openssl, …) are bundled-dep sources shared across
#     all PHP versions — fetched once and reused by every variant.
#   - phpVersions / xdebugVersions are two-level maps keyed by major.minor
#     (e.g. "8.5", "3.5"). Each PHP entry carries an `xdebug` pointer to
#     the xdebugVersions key it should pair with.
#   - latestPhp is the key used for the `default` flake output.

{
  zlib = {
    url = "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz";
    sha256 = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23";
    version = "1.3.1";
  };

  # OpenSSL 3.5.x is the current LTS line (supported through 2030). PBS
  # tracks 3.5.6; same pin and sha256 here.
  openssl = {
    url = "https://github.com/openssl/openssl/releases/download/openssl-3.5.6/openssl-3.5.6.tar.gz";
    sha256 = "deae7c80cba99c4b4f940ecadb3c3338b13cb77418409238e57d7f31f2a3b736";
    version = "3.5.6";
  };

  # libxml2 — foundational for dom/xml/xmlreader/xmlwriter/simplexml
  # extensions. Use the 2.13.x stable line. PHP 8.4 requires >= 2.9.4.
  libxml2 = {
    url = "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.5.tar.xz";
    sha256 = "74fc163217a3964257d3be39af943e08861263c4231f9ef5b496b6f6d4c7b2b6";
    version = "2.13.5";
  };

  # sqlite — for pdo_sqlite. The autoconf tarball name encodes the version
  # numerically (3470200 = 3.47.2), see build-sqlite.sh.
  sqlite = {
    url = "https://www.sqlite.org/2024/sqlite-autoconf-3470200.tar.gz";
    sha256 = "f1b2ee412c28d7472bc95ba996368d6f0cdcf00362affdadb27ed286c179540b";
    version = "3.47.2";
  };

  # oniguruma — regex engine for mbstring. NOTE: the tarball extracts
  # to onig-<ver>/ not oniguruma-<ver>/; build-oniguruma.sh handles that.
  oniguruma = {
    url = "https://github.com/kkos/oniguruma/releases/download/v6.9.10/onig-6.9.10.tar.gz";
    sha256 = "2a5cfc5ae259e4e97f86b68dfffc152cdaffe94e2060b770cb827238d769fc05";
    version = "6.9.10";
  };

  # libsodium — modern crypto for the sodium extension.
  libsodium = {
    url = "https://download.libsodium.org/libsodium/releases/libsodium-1.0.20.tar.gz";
    sha256 = "ebb65ef6ca439333c2bb41a0c1990587288da07f6c7fd07cb3a18cc18d30ce19";
    version = "1.0.20";
  };

  # bzip2 — for phar. Hand-rolled Makefile (not autotools); has separate
  # static / shared make targets, see build-bzip2.sh.
  bzip2 = {
    url = "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz";
    sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269";
    version = "1.0.8";
  };

  # libpng — for gd extension. Depends on zlib.
  libpng = {
    url = "https://download.sourceforge.net/libpng/libpng-1.6.44.tar.gz";
    sha256 = "8c25a7792099a0089fa1cc76c94260d0bb3f1ec52b93671b572f8bb61577b732";
    version = "1.6.44";
  };

  # libjpeg-turbo — for gd extension. cmake-based; SIMD disabled (would
  # need NASM in the toolchain). PHP gd uses the traditional libjpeg API,
  # not the TurboJPEG one — we drop libturbojpeg.so to keep the tarball
  # lean and avoid /nix/store-leak in tjbench's RPATH.
  libjpeg-turbo = {
    url = "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.0.4/libjpeg-turbo-3.0.4.tar.gz";
    sha256 = "99130559e7d62e8d695f2c0eaeef912c5828d5b84a0537dcb24c9678c9d5b76b";
    version = "3.0.4";
  };

  # libwebp — for gd extension. Internal libsharpyuv.so also gets built
  # (since libwebp 1.3.0); finalize.sh treats it like any other .so.
  libwebp = {
    url = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0.tar.gz";
    sha256 = "61f873ec69e3be1b99535634340d5bde750b2e4447caa1db9f61be3fd49ab1e5";
    version = "1.4.0";
  };

  # FreeType — for gd's TTF rendering (imagettftext et al). Depends on
  # zlib + bzip2 for compressed font tables. We disable libpng/harfbuzz/
  # brotli to keep the dep graph tractable for v1.
  freetype = {
    url = "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz";
    sha256 = "0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289";
    version = "2.13.3";
  };

  # nghttp2 — HTTP/2 protocol library; libcurl uses it for HTTP/2 support.
  # We build with --enable-lib-only to skip the C++ apps (nghttp/nghttpd/
  # h2load) that pull in libev/libxml2/jansson/jemalloc.
  nghttp2 = {
    url = "https://github.com/nghttp2/nghttp2/releases/download/v1.64.0/nghttp2-1.64.0.tar.gz";
    sha256 = "20e73f3cf9db3f05988996ac8b3a99ed529f4565ca91a49eb0550498e10621e8";
    version = "1.64.0";
  };

  # libzip — for the zip extension. cmake-based; uses zlib + bzip2 +
  # openssl (the latter for AES-encrypted entries). Skips lzma/zstd
  # which we don't bundle.
  libzip = {
    url = "https://github.com/nih-at/libzip/releases/download/v1.10.1/libzip-1.10.1.tar.gz";
    sha256 = "9669ae5dfe3ac5b3897536dc8466a874c8cf2c0e3b1fdd08d75b273884299363";
    version = "1.10.1";
  };

  # ICU — for the intl extension. First C++ dep. We static-link libstdc++
  # into libicu*.so (build-icu.sh adds -static-libstdc++) so the tarball
  # has no runtime libstdc++ dependency on consumer machines, AND so ICU's
  # build-time icupkg tool can run without LD_LIBRARY_PATH gymnastics.
  # Tarball extracts to icu/ rather than icu-<ver>/; build script renames.
  icu = {
    url = "https://github.com/unicode-org/icu/releases/download/release-75-1/icu4c-75_1-src.tgz";
    sha256 = "cb968df3e4d2e87e8b11c49a5d01c787bd13b9545280fc6642f826527618caef";
    version = "75.1";
  };

  # libcurl — for the curl extension. Wired with OpenSSL (TLS), nghttp2
  # (HTTP/2), and zlib (compression). All other optional protocols/codecs
  # are explicitly disabled so configure doesn't auto-detect host system
  # libs.
  libcurl = {
    url = "https://curl.se/download/curl-8.11.0.tar.gz";
    sha256 = "264537d90e58d2b09dddc50944baf3c38e7089151c8986715e2aaeaaf2b8118f";
    version = "8.11.0";
  };

  # ncurses — terminfo/terminal-capability library; needed by libedit as its
  # terminfo backend. We bundle it so the tarball works on minimal containers
  # that lack a system ncurses (Alpine musl, Ubuntu minimal, etc.).
  ncurses = {
    url = "https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz";
    sha256 = "136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6";
    version = "6.5";
  };

  # libedit — BSD editline library; provides line editing and history for
  # PHP's ext/readline (php -a interactive shell). We use libedit rather
  # than GNU readline because readline is GPL-licensed and redistributing
  # a PHP binary linked against it would impose GPL terms on the combined
  # work. Distros (Debian, Homebrew) make the same call.
  libedit = {
    url = "https://thrysoee.dk/editline/libedit-20240808-3.1.tar.gz";
    sha256 = "5f0573349d77c4a48967191cdd6634dd7aa5f6398c6a57fe037cc02696d6099f";
    version = "20240808-3.1";
  };

  # PHP version matrix. Each entry pairs a PHP major.minor with a specific
  # patch release and the xdebugVersions key it should use. New PHP versions
  # are added here; bundled deps above remain shared across all variants.
  #
  # Patch-version pins are deliberate: 8.1.30 / 8.2.20 / 8.3.8 were the first
  # releases to compile against libxml2 2.13 (the fix never made it into
  # earlier patches). We track the latest stable in each line and pin above
  # that floor so simplexml/dom/xml extensions build cleanly.
  phpVersions = {
    "8.1" = {
      version = "8.1.31";
      url = "https://www.php.net/distributions/php-8.1.31.tar.xz";
      sha256 = "c4f244d46ba51c72f7d13d4f66ce6a9e9a8d6b669c51be35e01765ba58e7afca";
      xdebug = "3.5";
    };
    "8.2" = {
      version = "8.2.26";
      url = "https://www.php.net/distributions/php-8.2.26.tar.xz";
      sha256 = "54747400cb4874288ad41a785e6147e2ff546cceeeb55c23c00c771ac125c6ef";
      xdebug = "3.5";
    };
    "8.3" = {
      version = "8.3.14";
      url = "https://www.php.net/distributions/php-8.3.14.tar.xz";
      sha256 = "58b4cb9019bf70c0cbcdb814c7df79b9065059d14cf7dbf48d971f8e56ae9be7";
      xdebug = "3.5";
    };
    "8.4" = {
      version = "8.4.3";
      url = "https://www.php.net/distributions/php-8.4.3.tar.xz";
      sha256 = "5c42173cbde7d0add8249c2e8a0c19ae271f41d8c47d67d72bdf91a88dcc7e4b";
      xdebug = "3.5";
    };
    "8.5" = {
      version = "8.5.5";
      url = "https://www.php.net/distributions/php-8.5.5.tar.xz";
      sha256 = "95bec382f4bd00570a8ef52a58ec04d8d9b9a90494781f1c106d1b274a3902f2";
      xdebug = "3.5";
    };
  };

  # xdebug version matrix. Keyed by series tag. PHP entries point here via
  # the `xdebug` field so the pairing is explicit and easy to update.
  #
  # We pin xdebug 3.5.1 because it is the first xdebug release with PHP 8.5
  # support (3.4.x's configure refuses any PHP >= 8.5.0). 3.5.x covers PHP
  # 8.1 through 8.5, so a single entry suffices for the whole range we ship.
  #
  # This is the headline use case for the entire project: dynamic-linked
  # PHP that can dlopen xdebug for development workflows. Building xdebug
  # via our shipped phpize also serves as an end-to-end cross-check of
  # the relocation patches (scripts/phpize.in / php-config.in).
  xdebugVersions = {
    "3.5" = {
      version = "3.5.1";
      url = "https://xdebug.org/files/xdebug-3.5.1.tgz";
      sha256 = "0f26849a5edf3d9120edc100219854599d54f923a8a4d1cb4fe4403520e49678";
    };
  };

  # The key into phpVersions that `default` and the unqualified CLI output
  # should resolve to. Bump this when a new stable PHP is promoted.
  latestPhp = "8.5";
}
