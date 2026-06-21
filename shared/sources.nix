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

  # libxslt — XSLT 1.0 processor; required by PHP's xsl extension (used by
  # Magento and other CMSes that render XML via XSLT). Built against our
  # bundled libxml2; libgcrypt (EXSLT crypto module) and libxslt's Python
  # bindings are explicitly disabled — see build-libxslt.sh.
  #
  # Pinned to 1.1.43 deliberately: 1.1.45 raised its libxml2 floor to
  # 2.15.1, which we don't yet ship (we're on 2.13.9). 1.1.43's floor is
  # 2.6.27 — clears our 2.13.9 trivially. Bump in lockstep with libxml2.
  libxslt = {
    url = "https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz";
    sha256 = "5a3d6b383ca5afc235b171118e90f5ff6aa27e9fea3303065231a6d403f0183a";
    version = "1.1.43";
  };

  # sqlite — for pdo_sqlite. The autoconf tarball name encodes the version
  # numerically (3470200 = 3.47.2), see build-sqlite.sh.
  sqlite = {
    url = "https://www.sqlite.org/2026/sqlite-autoconf-3530200.tar.gz";
    sha256 = "588ad51949419a56ebe81fe56193d510c559eb94c9a57748387860b5d3069316";
    version = "3.53.2";
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
    url = "https://ftp.postgresql.org/pub/source/v18.4/postgresql-18.4.tar.bz2";
    sha256 = "81a81ec695fb0c7901407defaa1d2f7973617154cf27ba74e3a7ab8e64436094";
    version = "18.4";
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

  # libgmp — GNU Multiple Precision arithmetic library. PHP's ext/gmp wraps
  # libgmp for arbitrary-precision integer/rational/float math; used by
  # JWT RSA/EC libraries, password hashers that compute modular exponents
  # in userland, and crypto/blockchain code. Pure autotools build, no
  # transitive deps.
  libgmp = {
    url = "https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz";
    sha256 = "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898";
    version = "6.3.0";
  };

  # libedit — BSD editline library; provides line editing and history for
  # PHP's ext/readline (php -a interactive shell). We use libedit rather
  # than GNU readline because readline is GPL-licensed and redistributing
  # a PHP binary linked against it would impose GPL terms on the combined
  # work. Distros (Debian, Homebrew) make the same call.
  libedit = {
    url = "https://thrysoee.dk/editline/libedit-20260512-3.1.tar.gz";
    sha256 = "432d5e7ea8b0116dd39f2eca7bc11d0eed77faa6b77ea526ace89907c23ea4a0";
    version = "20260512-3.1";
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
      version = "8.4.22";
      url = "https://www.php.net/distributions/php-8.4.22.tar.xz";
      sha256 = "696c0f6ad92e94c59059c1eb6e300842b8d050934226efcdf00f2a413cb083cf";
    };
    "8.5" = {
      version = "8.5.7";
      url = "https://www.php.net/distributions/php-8.5.7.tar.xz";
      sha256 = "01ba2ed1c2658dacf91bebc8be6a4885f69b811c7993831fc48e26107ab29985";
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

  # protobuf PECL extension. Native C implementation of Google Protocol
  # Buffers for PHP — the fast path for google/protobuf and grpc/grpc PHP
  # codegen, an order of magnitude faster than the pure-PHP fallback. No
  # external C-library — the upb runtime is vendored in the PECL source and
  # compiled in-tree via phpize.
  #
  # 4.33.x is the last series whose `package.xml` declares `<min>8.1.0`; the
  # 5.x line raised the floor to 8.2, which would drop the 8.1.34 leg of our
  # matrix. pickOnly requires a single series covering every shipped minor,
  # so we stay on 4.33.6 until 8.1 leaves the matrix.
  protobufVersions = {
    "4.33" = {
      version = "4.33.6";
      url = "https://pecl.php.net/get/protobuf-4.33.6.tgz";
      sha256 = "4b1e2d13c2086d647be6b6dd6648101d5ce36d83943834c724b0f399a4ecf836";
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

  # libxcrypt — the libcrypt.so.1 ABI was spun out of glibc in 2.39; this
  # is the reference implementation distros now ship as a separate package.
  # We bundle it (rather than rely on the consumer's libxcrypt being
  # installed) for the same reason we bundle openssl: avoid runtime
  # surprises on minimal containers and distros that strip libxcrypt.
  # MariaDB's auth plugins use crypt() for password hashing.
  libxcrypt = {
    url = "https://github.com/besser82/libxcrypt/releases/download/v4.4.36/libxcrypt-4.4.36.tar.xz";
    sha256 = "e5e1f4caee0a01de2aee26e3138807d6d3ca2b8e67287966d1fefd65e1fd8943";
    version = "4.4.36";
  };

  # MariaDB server. 11.4 is the current LTS line (supported through May 2029).
  # Built dynamically against bundled openssl / zlib / ncurses / pcre2 with
  # $ORIGIN-relative RPATHs so the install tree is relocatable. The same
  # bundled-dep set the PHP build uses is reused — no new shared/<dep>.nix
  # files are needed for MariaDB itself.
  mariadb = {
    url = "https://archive.mariadb.org/mariadb-11.4.12/source/mariadb-11.4.12.tar.gz";
    sha256 = "5ab7883db519bfcebfdd2aac09bc5544a12ce328f39edd46d0bf01690615ef6c";
    version = "11.4.12";
  };

  # Redis server. 8.x is the current stable line and is tri-licensed
  # (RSALv2 / SSPLv1 / AGPLv3) — bougie's use case is local dev, where the
  # AGPLv3 leg covers redistribution-as-a-tool cleanly. 7.2 and prior were
  # BSD-3; we don't pin those because every active release line has known
  # CVEs and the modules/clients PHP code depends on are 8.x-shaped.
  #
  # Built from the upstream Makefile (no autotools/cmake — redis ships its
  # own build system) with BUILD_TLS=yes against bundled openssl, MALLOC=
  # jemalloc (the upstream default; vendored under deps/jemalloc), and
  # USE_SYSTEMD=no. Linenoise + hiredis + lua + jemalloc are all vendored
  # under deps/; the only external library is OpenSSL. No new
  # shared/<dep>.nix files needed beyond what the PHP build already pulls
  # in.
  redis = {
    url = "https://github.com/redis/redis/archive/refs/tags/8.6.4.tar.gz";
    sha256 = "a2029c96311ab1ec2ae489076ae900b6497b3beaa7dc379de26b5df48f696f6c";
    version = "8.6.4";
  };

  # Erlang/OTP. Built from source — there's no Temurin-equivalent prebuilt
  # for Erlang that we'd trust to be relocatable across our libc floor, so
  # we take the source tarball and pass it through mkDep + finalize the
  # same way the C-library deps (and redis/mariadb) go through.
  #
  # 27.3.4.11 is the latest patch on the 27.x line as of 2026-05-14;
  # 27.x is the current OTP LTS-ish line and satisfies RabbitMQ 4.0.x's
  # supported-Erlang matrix (which accepts 26.x or 27.x). When bumping
  # OTP, re-check the RabbitMQ "Which Erlang for which RabbitMQ" matrix
  # before moving — RabbitMQ pins narrowly.
  #
  # External link deps surface through build-erlang.sh's configure flags:
  #   --with-ssl=$PBS_DEP_OPENSSL     crypto NIF links our bundled OpenSSL
  #   (zlib is auto-detected; we expose it via PBS_DEP_ZLIB)
  # All GUI bits (--without-{wx,debugger,observer,et}) and --without-javac
  # are disabled — we want a CLI/server VM, not the wxWidgets developer
  # tooling. JIT support, SMP, kernel-poll all stay enabled (defaults).
  #
  # Upstream tarball extracts to otp_src_<version>/ rather than
  # erlang-<version>/; build-erlang.sh handles that.
  erlang = {
    url = "https://github.com/erlang/otp/releases/download/OTP-27.3.4.11/otp_src_27.3.4.11.tar.gz";
    sha256 = "9d63382d3e7707c058dabe338114e09ff8228d54d29df794d907d3c8dddde5f9";
    version = "27.3.4.11";
  };

  # RabbitMQ. Repackaged from upstream's `generic-unix` release tarball
  # — pure Erlang bytecode (`.beam` / `.ez`) plus shell-script launchers,
  # no native code outside what comes from our injected Erlang. Same
  # OpenSearch-min playbook: one platform-agnostic source tarball serves
  # both linux and darwin, and the only host-specific artifact is the
  # bundled VM we inject under install/erlang/.
  #
  # Elixir is NOT a runtime dependency: RabbitMQ's CLI tools and several
  # of its plugins are written in Elixir, but the generic-unix tarball
  # ships pre-compiled `.beam` files plus the Elixir standard library's
  # `.beam` files inside each escript ZIP archive — Elixir's runtime is
  # just the Erlang VM running compiled Elixir bytecode. So the
  # tools/rabbitmq tree only needs to inject our standalone Erlang
  # (tools/erlang/), exactly like tools/opensearch injects tools/jdk.
  #
  # 4.2.6 is the latest stable patch on the 4.2 minor as of 2026-05-14.
  # RabbitMQ 4.x supports OTP 26.x and 27.x; we ship OTP 27 LTS. Bumping
  # RabbitMQ across a major requires re-checking the "Which Erlang for
  # which RabbitMQ" compatibility matrix at rabbitmq.com/docs/which-erlang.
  #
  # Upstream publishes a sha256 sidecar as well; we use sha512 here for
  # consistency with how tools/opensearch pins upstream's sha512.
  rabbitmq = {
    url = "https://github.com/rabbitmq/rabbitmq-server/releases/download/v4.2.6/rabbitmq-server-generic-unix-4.2.6.tar.xz";
    sha512 = "29346cc7fb175a591f67ed957ba462f8b70bebd08b8fddf8a458edca7a6cc4392f5d4c7fd5c461896d0954df1b5b3357d2aaa09413a55bde08c294b079491177";
    version = "4.2.6";
  };

  # NSPR — Netscape Portable Runtime. Standalone build (it's a foundation
  # library for NSS, exposing threads/IO/memory primitives). Autoconf
  # build, behaves; only present here because NSS needs it. v4.36 is
  # the most recent stable as of early 2026; bumps should track NSS's
  # `coreconf/coreconf.dep` floor.
  nspr = {
    url = "https://archive.mozilla.org/pub/nspr/releases/v4.39/src/nspr-4.39.tar.gz";
    sha256 = "bbd02ee87a55676063a63e5bc819e0227de2666b47307b2a0134414cdf42368e";
    version = "4.39";
  };

  # NSS — Network Security Services. Mozilla's TLS/crypto/cert-DB
  # library. PBS ships it solely so the mkcert bundle can call
  # `certutil` (NSS's CLI tool) to install the local-dev CA into
  # Firefox's per-profile cert9.db without manual import. Custom
  # gmake-based build; depends on NSPR. NSS releases track Firefox;
  # any modern tag works for certutil's purposes.
  nss = {
    url = "https://archive.mozilla.org/pub/security/nss/releases/NSS_3_124_RTM/src/nss-3.124.tar.gz";
    sha256 = "80da9f1cbcb267293b2248818d288bc02f874d6a34f1989a2828401d74a0bc9b";
    version = "3.124";
  };

  # mkcert — FiloSottile's local-CA generator. Pure-Go static binary;
  # at runtime invokes `certutil` (shipped alongside it via the NSS
  # build above) as a subprocess to manipulate Firefox's NSS cert
  # store. Not linked against libnss — the dep is a PATH/exec one.
  mkcert = {
    url = "https://github.com/FiloSottile/mkcert/archive/refs/tags/v1.4.4.tar.gz";
    sha256 = "32bd5519581bf0b03f53e5b22721692b99f39ab5b161dc27532c51eafa512ca9";
    version = "1.4.4";
  };

  # Eclipse Temurin JDK 21 (LTS). First entry that's published only as a
  # prebuilt binary — we don't build OpenJDK from source. Temurin Linux x64
  # is built on CentOS 7 (glibc 2.17), the same floor our manylinux-style
  # sysroot targets; macOS aarch64 builds target Big Sur (matches our
  # MACOSX_DEPLOYMENT_TARGET=11.0). Per-platform tarballs live under
  # `platforms.<system>`; flake.nix picks the entry for the current system.
  #
  # The 21.0.x line is the current LTS; 21.0.11+10 is the latest patch as
  # of 2026-05-14. Bump in lockstep with whatever OpenSearch's required
  # JDK is — OpenSearch 2.19 needs JDK 21.
  jdk = {
    version = "21.0.11+10";
    platforms = {
      "x86_64-linux" = {
        url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.11%2B10/OpenJDK21U-jdk_x64_linux_hotspot_21.0.11_10.tar.gz";
        sha256 = "4b2220e232a97997b436ca6ab15cbf70171ecff52958a46159dfa5a8c44ca4de";
      };
      "aarch64-darwin" = {
        url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.11%2B10/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.11_10.tar.gz";
        sha256 = "6ebcf221c9b41507b14c098e93c6ead6440b8d9bd154f8ec666c4c73abbdb201";
      };
    };
  };

  # Mailpit — axllent/mailpit, a single static Go SMTP test server + web
  # UI for local development. Like the JDK, published only as a prebuilt
  # binary (we don't compile it): the official linux builds are
  # CGO_ENABLED=0 static executables, so there is no glibc floor. The
  # release archive holds just `mailpit` + LICENSE + README at the root.
  # Per-platform assets live under `platforms.<system>`; flake.nix picks
  # the entry for the current system. Pinned in lockstep with the bougie
  # services catalog's mailpit version.
  mailpit = {
    version = "1.30.2";
    platforms = {
      "x86_64-linux" = {
        url = "https://github.com/axllent/mailpit/releases/download/v1.30.2/mailpit-linux-amd64.tar.gz";
        sha256 = "63b113aa9748adf7091b649ebe02693f99a459000cbe415faa6679f4b39f82cf";
      };
      "aarch64-darwin" = {
        url = "https://github.com/axllent/mailpit/releases/download/v1.30.2/mailpit-darwin-arm64.tar.gz";
        sha256 = "05b92a4b804c34b0f6e665a482a1141be64256f500ecf23a204c2084a27a248b";
      };
    };
  };

  # OpenSearch 2.19.5 (current 2.x LTS patch as of 2026-05-14). Single
  # platform-agnostic source: upstream's stable **min** (core-only)
  # release tarball. opensearch.nix wires our standalone Temurin
  # (tools/jdk/) in at install/jdk/ on both linux and darwin — the
  # bundled-JDK shape is identical across platforms.
  #
  # Why a single URL works for both platforms: OpenSearch min is 100%
  # platform-agnostic JVM bytecode (audited 2026-05-14). bin/ contains
  # only Bourne-shell launchers, zero ELF/Mach-O binaries ship outside
  # jdk/, and none of the 127 JAR files carry embedded native libs
  # (.so / .dylib / .jnilib). The OpenSearch core itself has no
  # platform-specific bits; upstream's per-platform tarballs only differ
  # in which JDK they bundle, and we always supply our own JDK. Picking
  # the Linux x64 release URL is arbitrary — same JARs ship to darwin.
  #
  # The releases/core/ path is stable + immutable (vs the snapshots/core/
  # path which moves forward when newer builds land). We don't have to
  # depend on a "-latest" alias.
  #
  # Users who want plugins (security, observability, alerting, sql, …)
  # install them with `opensearch-plugin install <name>` from the
  # OpenSearch plugin index. This matches bougie's dev-focused scope.
  #
  # OpenSearch publishes sha512 sidecars but not sha256 — we use sha512
  # here (fetchurl accepts either).
  opensearch = {
    url = "https://artifacts.opensearch.org/releases/core/opensearch/2.19.5/opensearch-min-2.19.5-linux-x64.tar.gz";
    sha512 = "9e74a9510044c53565a5aa72ba6a18cd0dcbe46fdd2666eeaf473528bd2f7ecf1bf0f8461154986270b8565c7feeb9543e246eaa956dd065c98db96fed83c389";
    version = "2.19.5";
  };

  # OpenSearch plugins shipped by default in the tarball. The Nix
  # sandbox has no network access, so we can't run
  # `opensearch-plugin install` at build time — instead we pre-fetch
  # the plugin ZIPs as fixed-output derivations and extract them into
  # install/plugins/<name>/ in tools/opensearch/opensearch.nix.
  #
  # The plugin version MUST match the OpenSearch version exactly —
  # OpenSearch refuses to load a plugin whose `opensearch.version` in
  # its plugin-descriptor.properties doesn't match the running core.
  # Bumping sources.opensearch.version requires bumping the plugin
  # versions in lockstep.
  #
  # Plugin selection criteria: pick plugins that
  #   (1) are useful to a meaningful fraction of dev users,
  #   (2) are pure-JVM (plus their JAR-internal native libs, if any —
  #       these load lazily via JNI's classpath fallback, so still
  #       cross-platform),
  #   (3) don't require external configuration to start safely.
  #
  # analysis-icu: Lucene's ICU integration. Provides Unicode-aware
  #   tokenizers, normalizers, folders, collation. Standard pick for
  #   any non-English text search. Pure JVM (Lucene ICU is bytecode-
  #   only at runtime; the ICU C library isn't called).
  # analysis-phonetic: Soundex / Metaphone / Caverphone / etc.
  #   Common for name search ("find users named 'Smith' OR 'Smyth'").
  #   Pure JVM.
  opensearch-analysis-icu = {
    url = "https://artifacts.opensearch.org/releases/plugins/analysis-icu/2.19.5/analysis-icu-2.19.5.zip";
    sha512 = "28df1bf2d505ccd4ec6e4f96150228671e4799d3102f266e651d359206eca68adcd1bd0d31c630b30ad54fbc950dc560aa8781b85d1790a15736d23e91f8b97b";
    version = "2.19.5";
  };
  opensearch-analysis-phonetic = {
    url = "https://artifacts.opensearch.org/releases/plugins/analysis-phonetic/2.19.5/analysis-phonetic-2.19.5.zip";
    sha512 = "4994a3017df9cd086e4abe59ed2afe72084fc172c6ec2af953fb10f527e8f740062393e62c82ffd189a91ad930912b87661d82f7e1c5398c0e2b64f77ad1acb6";
    version = "2.19.5";
  };
}
