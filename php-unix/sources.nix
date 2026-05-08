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
    url = "https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz";
    sha256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16";
    version = "1.3.2";
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
    url = "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.9.tar.xz";
    sha256 = "a2c9ae7b770da34860050c309f903221c67830c86e4a7e760692b803df95143a";
    version = "2.13.9";
  };

  # sqlite — for pdo_sqlite. The autoconf tarball name encodes the version
  # numerically (3470200 = 3.47.2), see build-sqlite.sh.
  sqlite = {
    url = "https://www.sqlite.org/2026/sqlite-autoconf-3530100.tar.gz";
    sha256 = "83e6b2020a034e9a7ad4a72feea59e1ad52f162e09cbd26735a3ffb98359fc4f";
    version = "3.53.1";
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
    url = "https://download.libsodium.org/libsodium/releases/libsodium-1.0.22.tar.gz";
    sha256 = "adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349";
    version = "1.0.22";
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
    url = "https://download.sourceforge.net/libpng/libpng-1.6.58.tar.gz";
    sha256 = "8c9b05b675ca7301a458df2c2e46f26e1d41ff36b8863f8c33530bc58c2e6225";
    version = "1.6.58";
  };

  # libjpeg-turbo — for gd extension. cmake-based; SIMD disabled (would
  # need NASM in the toolchain). PHP gd uses the traditional libjpeg API,
  # not the TurboJPEG one — we drop libturbojpeg.so to keep the tarball
  # lean and avoid /nix/store-leak in tjbench's RPATH.
  libjpeg-turbo = {
    url = "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.4.1/libjpeg-turbo-3.1.4.1.tar.gz";
    sha256 = "ecae8008e2cc9ade2f2c1bb9d5e6d4fb73e7c433866a056bd82980741571a022";
    version = "3.1.4.1";
  };

  # libwebp — for gd extension. Internal libsharpyuv.so also gets built
  # (since libwebp 1.3.0); finalize.sh treats it like any other .so.
  libwebp = {
    url = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz";
    sha256 = "e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564";
    version = "1.6.0";
  };

  # FreeType — for gd's TTF rendering (imagettftext et al). Depends on
  # zlib + bzip2 for compressed font tables. We disable libpng/harfbuzz/
  # brotli to keep the dep graph tractable for v1.
  freetype = {
    url = "https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz";
    sha256 = "36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f";
    version = "2.14.3";
  };

  # nghttp2 — HTTP/2 protocol library; libcurl uses it for HTTP/2 support.
  # We build with --enable-lib-only to skip the C++ apps (nghttp/nghttpd/
  # h2load) that pull in libev/libxml2/jansson/jemalloc.
  nghttp2 = {
    url = "https://github.com/nghttp2/nghttp2/releases/download/v1.69.0/nghttp2-1.69.0.tar.gz";
    sha256 = "c866b7477cbb7512ab6863a685027adbb1bb8da8fc3bab7429ed43d3281d5aa9";
    version = "1.69.0";
  };

  # libzip — for the zip extension. cmake-based; uses zlib + bzip2 +
  # openssl (the latter for AES-encrypted entries). Skips lzma/zstd
  # which we don't bundle.
  libzip = {
    url = "https://github.com/nih-at/libzip/releases/download/v1.11.4/libzip-1.11.4.tar.gz";
    sha256 = "82e9f2f2421f9d7c2466bbc3173cd09595a88ea37db0d559a9d0a2dc60dc722e";
    version = "1.11.4";
  };

  # ICU — for the intl extension. First C++ dep. We static-link libstdc++
  # into libicu*.so (build-icu.sh adds -static-libstdc++) so the tarball
  # has no runtime libstdc++ dependency on consumer machines, AND so ICU's
  # build-time icupkg tool can run without LD_LIBRARY_PATH gymnastics.
  # Tarball extracts to icu/ rather than icu-<ver>/; build script renames.
  icu = {
    url = "https://github.com/unicode-org/icu/releases/download/release-77-1/icu4c-77_1-src.tgz";
    sha256 = "588e431f77327c39031ffbb8843c0e3bc122c211374485fa87dc5f3faff24061";
    version = "77.1";
  };

  # libcurl — for the curl extension. Wired with OpenSSL (TLS), nghttp2
  # (HTTP/2), and zlib (compression). All other optional protocols/codecs
  # are explicitly disabled so configure doesn't auto-detect host system
  # libs.
  libcurl = {
    url = "https://curl.se/download/curl-8.20.0.tar.gz";
    sha256 = "fc5819cad3f9f5482669adcdc49a782c15f36d2a0715b395b06d9173593d2dc0";
    version = "8.20.0";
  };

  # ncurses — terminfo/terminal-capability library; needed by libedit as its
  # terminfo backend. We bundle it so the tarball works on minimal containers
  # that lack a system ncurses (Alpine musl, Ubuntu minimal, etc.).
  ncurses = {
    url = "https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz";
    sha256 = "355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11";
    version = "6.6";
  };

  # libiconv — character set conversion library. Bundled on Darwin only:
  # glibc provides iconv as part of libc, so the Linux build doesn't need
  # this dep. Apple's macOS ships libiconv.2.dylib as a system library
  # but its headers live in the SDK and aren't visible inside the Nix
  # sandbox; PHP's configure does a literal `test -r $prefix/include/iconv.h`
  # which fails. Bundling resolves both halves: configure finds the header
  # and the resulting PHP links against our /nix-store-built libiconv,
  # which finalize then relocates to @rpath like every other dep.
  libiconv = {
    url = "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.19.tar.gz";
    sha256 = "88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6";
    version = "1.19";
  };

  # libedit — BSD editline library; provides line editing and history for
  # PHP's ext/readline (php -a interactive shell). We use libedit rather
  # than GNU readline because readline is GPL-licensed and redistributing
  # a PHP binary linked against it would impose GPL terms on the combined
  # work. Distros (Debian, Homebrew) make the same call.
  libedit = {
    url = "https://thrysoee.dk/editline/libedit-20251016-3.1.tar.gz";
    sha256 = "21362b00653bbfc1c71f71a7578da66b5b5203559d43134d2dd7719e313ce041";
    version = "20251016-3.1";
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
      version = "8.1.34";
      url = "https://www.php.net/distributions/php-8.1.34.tar.xz";
      sha256 = "ffa9e0982e82eeaea848f57687b425ed173aa278fe563001310ae2638db5c251";
      xdebug = "3.5";
    };
    "8.2" = {
      version = "8.2.31";
      url = "https://www.php.net/distributions/php-8.2.31.tar.xz";
      sha256 = "95eae411d594fe6f6e5678b76645dc13ae47d3c0a5325c1d969b58dea56ee45a";
      xdebug = "3.5";
    };
    "8.3" = {
      version = "8.3.31";
      url = "https://www.php.net/distributions/php-8.3.31.tar.xz";
      sha256 = "66410cee07f4b2baeb0843140bb2a2b52ef930b5cf9b3d6e6d158b33aae8fa37";
      xdebug = "3.5";
    };
    "8.4" = {
      version = "8.4.21";
      url = "https://www.php.net/distributions/php-8.4.21.tar.xz";
      sha256 = "7cf5d8ab12c3b2016875bcfaec71bef1ef0b07bed6148f2c447577074431f984";
      xdebug = "3.5";
    };
    "8.5" = {
      version = "8.5.6";
      url = "https://www.php.net/distributions/php-8.5.6.tar.xz";
      sha256 = "826c600b7c6f956bd335558ca3bdbcab23b22126c1cc8d9348be2280a2204bb7";
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
