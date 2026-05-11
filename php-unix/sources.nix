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
#   - phpVersions describes PHP itself only (version + tarball + sha256),
#     keyed by major.minor (e.g. "8.5").
#   - <ext>Versions (xdebugVersions, imagickVersions, redisVersions,
#     vipsVersions) are independent single-entry maps keyed by series tag.
#     Today every PHP minor pairs with the one entry in each map; the
#     resolver in flake.nix takes the single value directly. When/if a
#     second series ever needs different PHP coverage, add an
#     extensionMatrix sibling table here with a per-PHP-minor selector.
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

  # libpq — PostgreSQL client library, for the pgsql + pdo_pgsql extensions.
  # Built from the full PostgreSQL source tarball but only the client subtree
  # (src/common, src/port, src/interfaces/libpq, src/bin/pg_config, src/include)
  # is compiled and installed — see build-libpq.sh. Wired against our bundled
  # OpenSSL so libpq supports TLS connections (sslmode=require et al).
  libpq = {
    url = "https://ftp.postgresql.org/pub/source/v17.2/postgresql-17.2.tar.bz2";
    sha256 = "82ef27c0af3751695d7f64e2d963583005fbb6a0c3df63d0e4b42211d7021164";
    version = "17.2";
  };

  # libtiff — TIFF reader/writer, an ImageMagick delegate. Depends on zlib
  # (DEFLATE) + libjpeg-turbo (JPEG-in-TIFF). lzma/zstd backends are off
  # to match the rest of the bundle. Pulled in by ImageMagick's --with-tiff.
  libtiff = {
    url = "https://download.osgeo.org/libtiff/tiff-4.7.0.tar.gz";
    sha256 = "67160e3457365ab96c5b3286a0903aa6e78bdc44c4bc737d2e486bcecb6ba976";
    version = "4.7.0";
  };

  # lcms2 — Little CMS color-management library. ImageMagick uses it for
  # ICC-profile-aware color conversion (--with-lcms). Self-contained, no
  # external deps.
  lcms2 = {
    url = "https://github.com/mm2/Little-CMS/releases/download/lcms2.17/lcms2-2.17.tar.gz";
    sha256 = "d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074";
    version = "2.17";
  };

  # openjpeg — JPEG 2000 (.jp2) codec, ImageMagick delegate. Cmake-based.
  # The github archive extracts to openjpeg-<ver>/.
  openjpeg = {
    url = "https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.3.tar.gz";
    sha256 = "368fe0468228e767433c9ebdea82ad9d801a3ad1e4234421f352c8b06e7aa707";
    version = "2.5.3";
  };

  # libde265 — HEVC/H.265 decoder, used as the decoder backend for libheif.
  # We don't bundle x265 (the encoder); imagick's typical use is HEIC read,
  # not write, and skipping x265 keeps the dep tree small + sidesteps the
  # GPL-licensed encoder.
  libde265 = {
    url = "https://github.com/strukturag/libde265/releases/download/v1.0.16/libde265-1.0.16.tar.gz";
    sha256 = "b92beb6b53c346db9a8fae968d686ab706240099cdd5aff87777362d668b0de7";
    version = "1.0.16";
  };

  # libheif — HEIF/HEIC container library; ImageMagick delegate (--with-heic).
  # Cmake-based. Decode-only configuration — depends on libde265 only;
  # libaom / x265 / dav1d / kvazaar / svt-av1 encoders are all disabled.
  libheif = {
    url = "https://github.com/strukturag/libheif/releases/download/v1.20.1/libheif-1.20.1.tar.gz";
    sha256 = "55cc76b77c533151fc78ba58ef5ad18562e84da403ed749c3ae017abaf1e2090";
    version = "1.20.1";
  };

  # ImageMagick — image manipulation library. The C library ImageMagick (7.x
  # MagickWand API) is consumed by the imagick PECL extension. Wired against
  # our bundled image-format delegates: png/jpeg/webp/freetype/xml/zlib/bzip2
  # (already shared), plus tiff/lcms2/openjp2/heif (added alongside this).
  # Heavy delegates explicitly disabled: rsvg, ghostscript, raw, openexr,
  # djvu, jbig, lzma, fftw, fpx, fontconfig, x11, perl, c++ bindings.
  # Tarball extracts to ImageMagick-<version>/ (Pascal-cased), not
  # imagemagick-<version>/.
  imagemagick = {
    url = "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/7.1.2-21.tar.gz";
    sha256 = "4ba5b81797910efa93e65fb5a02b496284b8069d64513c6d2687c80d180dd70f";
    version = "7.1.2-21";
  };

  # libffi — closures / FFI runtime. Required transitively by glib (GObject
  # closures invoke C callbacks via libffi); also pulled in by libvips. We
  # build it from upstream rather than relying on a system copy so the musl
  # / old-glibc Linux portability story stays intact.
  libffi = {
    url = "https://github.com/libffi/libffi/releases/download/v3.4.8/libffi-3.4.8.tar.gz";
    sha256 = "bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b";
    version = "3.4.8";
  };

  # PCRE2 — Perl-compatible regex engine. Required by glib (GRegex);
  # glib 2.74+ removed the ability to use a bundled PCRE copy. Built with
  # 8-bit code units (the configure default; matches every distro packaging).
  pcre2 = {
    url = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.gz";
    sha256 = "0e138387df7835d7403b8351e2226c1377da804e0737db0e071b48f07c9d12ee";
    version = "10.45";
  };

  # proxy-libintl — Darwin-only stub for the gettext intl API. macOS's
  # libc doesn't provide dgettext/bindtextdomain/etc.; glib 2.82's meson
  # depends on `intl` independently of NLS and falls back to the
  # proxy-libintl meson subproject. The wrap file uses wrap-git, which
  # needs network + git access neither of which is available inside the
  # Nix sandbox. We pre-populate subprojects/proxy-libintl/ from this
  # tarball in build-glib.sh.
  proxy-libintl = {
    url = "https://github.com/frida/proxy-libintl/archive/refs/tags/0.4.tar.gz";
    sha256 = "13ef3eea0a3bc0df55293be368dfbcff5a8dd5f4759280f28e030d1494a5dffb";
    version = "0.4";
  };

  # GLib — the GLib/GObject/GIO foundation. Required by libvips (libvips's
  # core types are GObject classes; image I/O goes through GIO streams).
  # First meson-based dep we ship; build-glib.sh handles the meson/ninja
  # invocation. We disable everything optional we can: no docs, no tests,
  # no introspection, no Tracing/Sysprof, NLS off (gettext at runtime is
  # only used for message translations which we don't ship), no man pages.
  glib = {
    url = "https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz";
    sha256 = "05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f";
    version = "2.82.5";
  };

  # expat — small streaming XML parser. Required by libvips unconditionally
  # (libvips uses expat's SAX API for parsing ICC profile descriptions and
  # libheif's nclx metadata). We already bundle libxml2 but libvips's
  # configure does not accept it as an alternative. Trivially-built
  # autotools dep, no transitive deps.
  expat = {
    url = "https://github.com/libexpat/libexpat/releases/download/R_2_7_2/expat-2.7.2.tar.xz";
    sha256 = "21b778b34ec837c2ac285aef340f9fb5fa063a811b21ea4d2412a9702c88995c";
    version = "2.7.2";
  };

  # libvips — image processing library; consumed by the vips PECL extension
  # for fast, low-memory image manipulation. meson-based. Built minimal:
  # only the image format delegates we already bundle (libpng, libjpeg,
  # libwebp, libtiff, libheif, lcms2). All other optional deps are
  # disabled to keep the dep graph tractable: fft, orc, librsvg, openexr,
  # poppler, openslide, libimagequant, libexif, magick (we don't link to
  # ImageMagick from libvips even though we bundle it elsewhere), pdfium,
  # cgif, matio, niftiio, nifticlib, fontconfig, pangocairo.
  libvips = {
    url = "https://github.com/libvips/libvips/releases/download/v8.16.1/vips-8.16.1.tar.xz";
    sha256 = "d114d7c132ec5b45f116d654e17bb4af84561e3041183cd4bfd79abfb85cf724";
    version = "8.16.1";
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

  # PHP version matrix. Each entry is a PHP major.minor pinned to a specific
  # patch release. PHP entries describe PHP and only PHP — extension series
  # pairings live in the per-extension <ext>Versions maps below and are
  # resolved by flake.nix.
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
    };
    "8.2" = {
      version = "8.2.31";
      url = "https://www.php.net/distributions/php-8.2.31.tar.xz";
      sha256 = "95eae411d594fe6f6e5678b76645dc13ae47d3c0a5325c1d969b58dea56ee45a";
    };
    "8.3" = {
      version = "8.3.31";
      url = "https://www.php.net/distributions/php-8.3.31.tar.xz";
      sha256 = "66410cee07f4b2baeb0843140bb2a2b52ef930b5cf9b3d6e6d158b33aae8fa37";
    };
    "8.4" = {
      version = "8.4.21";
      url = "https://www.php.net/distributions/php-8.4.21.tar.xz";
      sha256 = "7cf5d8ab12c3b2016875bcfaec71bef1ef0b07bed6148f2c447577074431f984";
    };
    "8.5" = {
      version = "8.5.6";
      url = "https://www.php.net/distributions/php-8.5.6.tar.xz";
      sha256 = "826c600b7c6f956bd335558ca3bdbcab23b22126c1cc8d9348be2280a2204bb7";
    };
  };

  # xdebug version matrix. Keyed by series tag. The flake's resolver reads
  # the single entry directly today; if a second series ever needs different
  # PHP coverage, add an extensionMatrix sibling table that selects per
  # PHP minor.
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

  # imagick PECL extension version matrix. Keyed by series tag, parallel to
  # xdebugVersions. 3.8.x is the first stable line that compiles cleanly
  # against PHP 8.4/8.5 — older 3.7.x has known break-points on those
  # PHP versions. Single entry covers PHP 8.1 through 8.5.
  imagickVersions = {
    "3.8" = {
      version = "3.8.1";
      url = "https://pecl.php.net/get/imagick-3.8.1.tgz";
      sha256 = "3a3587c0a524c17d0dad9673a160b90cd776e836838474e173b549ed864352ee";
    };
  };

  # phpredis (the `redis` PECL extension) version matrix. 6.3.x covers PHP
  # 8.0 through 8.5. Built with the default feature set: no igbinary,
  # msgpack, lzf, zstd, or lz4 backends — those would each need their own
  # bundled dep and are typically opt-in. The wire protocol still works
  # against any redis-server regardless; the optional backends only affect
  # SERIALIZER_/COMPRESSION_ choices that user code can request.
  redisVersions = {
    "6.3" = {
      version = "6.3.0";
      url = "https://pecl.php.net/get/redis-6.3.0.tgz";
      sha256 = "0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5";
    };
  };
  # vips PECL extension version matrix. Keyed by series tag, parallel to
  # imagickVersions. 1.0.13 is the current stable line; covers PHP 8.x.
  vipsVersions = {
    "1.0" = {
      version = "1.0.13";
      url = "https://pecl.php.net/get/vips-1.0.13.tgz";
      sha256 = "4e655843e5ee8150c927c10853dfa0d2a3b924bc2453ed8fb5e5a2a90e686f8f";
    };
  };

  # igbinary PECL extension. Fast binary serializer, an order of magnitude
  # smaller and faster than serialize() / json_encode() for round-tripping
  # PHP values. Commonly used as a serializer backend for Redis (phpredis)
  # and Memcached. No external C-library — pure C built via phpize.
  #
  # 3.2.17RC1 is the first release that compiles against PHP 8.4+ — the
  # 3.2.16 stable predates PHP's removal of `ext/standard/php_smart_string.h`
  # (replaced by Zend/zend_smart_string.h) and fails to build on 8.4/8.5.
  # PECL's <s>stable</s> tag flags 3.2.17RC1 as stable despite the RC suffix.
  igbinaryVersions = {
    "3.2" = {
      version = "3.2.17RC1";
      url = "https://pecl.php.net/get/igbinary-3.2.17RC1.tgz";
      sha256 = "91da821443db125282a6aea039f24588dd28ff5d71e8187f6ecc41165bceafbc";
    };
  };

  # msgpack PECL extension. MessagePack codec — alternative compact serializer.
  # Like igbinary, an opt-in serializer backend for Redis/Memcached. 3.0.0 is
  # the first stable release supporting PHP 8.4+. No external C-library — the
  # MessagePack format implementation is vendored in the PECL source.
  msgpackVersions = {
    "3.0" = {
      version = "3.0.0";
      url = "https://pecl.php.net/get/msgpack-3.0.0.tgz";
      sha256 = "55306a84797d399c6b269181ec484634f18bea1330bbd9d7405043c597de69cd";
    };
  };

  # pcov PECL extension. Code-coverage driver for PHPUnit / Pest, an order
  # of magnitude faster than xdebug's coverage mode and the standard pick
  # when xdebug's other features (step debugging, var dumps, tracing) aren't
  # also wanted. No external C-library — built via phpize. 1.0.x covers PHP
  # 7.1 through 8.5.
  pcovVersions = {
    "1.0" = {
      version = "1.0.12";
      url = "https://pecl.php.net/get/pcov-1.0.12.tgz";
      sha256 = "23255c8c9335a9636ccb743f5302436a97a582a0bbde9869485be911bbc15da8";
    };
  };

  # APCu PECL extension. Userspace shared-memory cache; the standard backend
  # for Symfony's `cache.app`, Laravel's array-cache-with-process-persistence,
  # Composer's class-loader cache, and many other libraries. No external
  # C-library — POSIX shm/mmap only. 5.1.x covers PHP 7.0 through 8.5.
  apcuVersions = {
    "5.1" = {
      version = "5.1.24";
      url = "https://pecl.php.net/get/apcu-5.1.24.tgz";
      sha256 = "5c28a55b27082c69657e25b7ecf553e2cf6b74ec3fa77d6b76f4fb982e001e43";
    };
  };

  # The key into phpVersions that `default` and the unqualified CLI output
  # should resolve to. Bump this when a new stable PHP is promoted.
  latestPhp = "8.5";
}
