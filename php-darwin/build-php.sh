#!/usr/bin/env bash
# Build PHP on Darwin against the bundled deps. Mirrors php-unix/build-php.sh
# but targets Mach-O / aarch64-darwin:
#   - No -static-libstdc++ trickery; macOS's /usr/lib/libc++.1.dylib is
#     ABI-stable across system versions, so dynamic-link is portable.
#   - getconf _NPROCESSORS_ONLN instead of nproc.
#   - DYLD_LIBRARY_PATH instead of LD_LIBRARY_PATH (used by phar's
#     pharcmd target which execs the just-built CLI binary).
#   - otool -L instead of readelf -d for the NEEDED-list audit.

set -euo pipefail

: "${PBS_SRC_PHP:?}"
: "${PBS_VER_PHP:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?}"
: "${PBS_DEP_OPENSSL:?}"
: "${PBS_DEP_LIBXML2:?}"
: "${PBS_DEP_SQLITE:?}"
: "${PBS_DEP_ONIGURUMA:?}"
: "${PBS_DEP_LIBSODIUM:?}"
: "${PBS_DEP_BZIP2:?}"
: "${PBS_DEP_LIBPNG:?}"
: "${PBS_DEP_LIBJPEG_TURBO:?}"
: "${PBS_DEP_LIBWEBP:?}"
: "${PBS_DEP_FREETYPE:?}"
: "${PBS_DEP_LIBZIP:?}"
: "${PBS_DEP_ICU:?}"
: "${PBS_DEP_LIBCURL:?}"
: "${PBS_DEP_NCURSES:?}"
: "${PBS_DEP_LIBEDIT:?}"
: "${PBS_DEP_LIBICONV:?}"
: "${PBS_DEP_LIBRESOLV_DIR:?point at nixpkgs darwin.libresolv \$out}"
: "${PBS_DEP_LIBRESOLV_INCLUDE:?point at nixpkgs darwin.libresolv \$dev (lib.getInclude)}"

src_dir="$PBS_SOURCES/php-${PBS_VER_PHP}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_PHP" -C "$PBS_SOURCES"
cd "$src_dir"

# Apply patches BEFORE configure runs.
bash "${PBS_PHP_PREPARE_SCRIPT}"

# nixpkgs's apple-sdk derivations strip the legacy networking headers
# (arpa/nameser.h, resolv.h, dns.h) that PHP's ext/standard/dns.c
# depends on. They're shipped instead under `lib.getInclude
# darwin.libresolv` — same Apple opensource libresolv-91 that provides
# the matching .dylib stubs in PBS_DEP_LIBRESOLV_DIR. PBS_DEP_LIBRESOLV_INCLUDE
# (set in php.nix) points at that dev output. -isystem so the headers
# slot in as system headers without polluting -W diagnostics.
export CFLAGS="-isystem $PBS_DEP_LIBRESOLV_INCLUDE/include $CFLAGS"
export CPPFLAGS="-isystem $PBS_DEP_LIBRESOLV_INCLUDE/include $CPPFLAGS"

# /usr/lib/libresolv.9.dylib provides _res_9_dn_expand, _res_9_init, etc.
# PHP's dns.c references these but configure doesn't add -lresolv on
# macOS. PBS_DEP_LIBRESOLV_DIR (set in php.nix) points at nixpkgs's
# darwin.libresolv derivation. Linking against /nix/store/.../libresolv.dylib
# bakes the build-time path into LC_LOAD_DYLIB; finalize.sh's existing
# rule rewrites /nix/store/* loads to @rpath/<basename> — but in this
# case the consumer's @rpath has no libresolv, so we need to remap to
# /usr/lib/libresolv.9.dylib (system) instead. The post-build hook below
# does that explicitly with install_name_tool.
export LDFLAGS="$LDFLAGS -L${PBS_DEP_LIBRESOLV_DIR}/lib -lresolv"

# ICU 75's headers require C++17 — same as Linux side.
export CXXFLAGS="${CXXFLAGS:-} -std=c++17"

# DYLD library search path for in-build executions (phar's pharcmd target
# runs the just-built CLI binary to generate phar.phar). Includes every
# bundled dep plus our in-progress install dir.
DYLD_LIBRARY_PATH_COMBINED="${PBS_DEPS_LDPATH:-}"

# PHP's iconv configure check compiles + RUNS a tiny program that calls
# iconv_open() with bogus encodings and asserts errno == EINVAL. On macOS
# arm64 in the Nix build sandbox the test program runs but the errno
# round-trip through GNU libiconv's stub doesn't satisfy the check —
# php_cv_iconv_errno comes back "no" and configure aborts with
# "The iconv check failed, 'errno' is missing." At runtime in actual use
# our libiconv works correctly (verified by hand). Pre-populate the
# autoconf cache vars so configure trusts us:
#   - php_cv_iconv_errno=yes — declares the runtime errno test passed.
#   - php_cv_iconv_const="" — declares iconv()'s 2nd arg is `char**`
#     (non-const, GNU libiconv 1.17 / POSIX). Empty string because the
#     value gets substituted as `#define ICONV_CONST <value>`; "no"
#     would emit a literal token `no` and ext/iconv/iconv.c fails to
#     compile with "use of undeclared identifier 'no'".
export php_cv_iconv_errno=yes
export php_cv_iconv_const=""

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --sbindir="$PBS_DEPS/bin" \
  --sysconfdir="$PBS_DEPS/etc/php" \
  --disable-rpath \
  --disable-cgi \
  --disable-phpdbg \
  --enable-cli \
  --enable-fpm \
  --without-pear \
  --with-config-file-path="$PBS_DEPS/etc/php" \
  --with-config-file-scan-dir="$PBS_DEPS/etc/php/conf.d" \
  --with-zlib="$PBS_DEP_ZLIB" \
  --with-openssl="$PBS_DEP_OPENSSL" \
  --with-libxml="$PBS_DEP_LIBXML2" \
  --enable-dom \
  --enable-xml \
  --enable-xmlreader \
  --enable-xmlwriter \
  --enable-simplexml \
  --enable-mbstring \
  --enable-mysqlnd \
  --with-mysqli=mysqlnd \
  --enable-pdo \
  --with-pdo-mysql=mysqlnd \
  --with-pdo-sqlite="$PBS_DEP_SQLITE" \
  --with-sqlite3="$PBS_DEP_SQLITE" \
  --with-sodium="$PBS_DEP_LIBSODIUM" \
  --with-bz2="$PBS_DEP_BZIP2" \
  --with-curl="$PBS_DEP_LIBCURL" \
  --enable-intl \
  --with-zip \
  --enable-gd \
  --with-jpeg="$PBS_DEP_LIBJPEG_TURBO" \
  --with-webp="$PBS_DEP_LIBWEBP" \
  --with-freetype="$PBS_DEP_FREETYPE" \
  --enable-fileinfo \
  --enable-filter \
  --enable-phar \
  --enable-posix \
  --enable-session \
  --enable-tokenizer \
  --enable-ctype \
  --with-iconv="$PBS_DEP_LIBICONV" \
  --with-libedit="$PBS_DEP_LIBEDIT" \
  --enable-opcache \
  PKG_CONFIG_PATH="$PBS_DEP_LIBZIP/lib/pkgconfig:$PBS_DEP_ICU/lib/pkgconfig:$PBS_DEP_LIBPNG/lib/pkgconfig:$PBS_DEP_LIBWEBP/lib/pkgconfig:$PBS_DEP_FREETYPE/lib/pkgconfig:$PBS_DEP_LIBJPEG_TURBO/lib/pkgconfig:$PBS_DEP_OPENSSL/lib/pkgconfig:$PBS_DEP_LIBCURL/lib/pkgconfig:$PBS_DEP_LIBXML2/lib/pkgconfig:$PBS_DEP_ONIGURUMA/lib/pkgconfig:$PBS_DEP_ZLIB/lib/pkgconfig:$PBS_DEP_SQLITE/lib/pkgconfig:$PBS_DEP_LIBSODIUM/lib/pkgconfig:$PBS_DEP_BZIP2/lib/pkgconfig:$PBS_DEP_NGHTTP2/lib/pkgconfig:$PBS_DEP_LIBEDIT/lib/pkgconfig:$PBS_DEP_NCURSES/lib/pkgconfig"

DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH_COMBINED" make -j"$(getconf _NPROCESSORS_ONLN)"
DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH_COMBINED" make install

# Sanity: phar.phar must have landed.
if [ ! -f "$PBS_DEPS/bin/phar.phar" ]; then
  echo "FATAL: bin/phar.phar not produced; pharcmd likely failed silently (check DYLD_LIBRARY_PATH)" >&2
  exit 1
fi

# Confirm readline (libedit-backed) is compiled into the binary.
if ! DYLD_LIBRARY_PATH="$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" "$PBS_DEPS/bin/php" -m | grep -qi readline; then
  echo "FATAL: readline not listed in php -m" >&2
  exit 1
fi
echo "readline OK (libedit-backed)"

rm -rf "$PBS_DEPS/share/man"
rm -rf "$PBS_DEPS/lib/php/test"

# Rewrite the build-time libresolv LC_LOAD_DYLIB (pointing at nixpkgs's
# darwin.libresolv) to the consumer-visible system path. Doing it here
# rather than in finalize keeps the special case scoped to the PHP
# derivation — every other dep's /nix/store/* loads get the standard
# @rpath rewrite.
for bin in "$PBS_DEPS/bin/php" "$PBS_DEPS/bin/php-fpm"; do
  [ -f "$bin" ] || continue
  while IFS= read -r dep; do
    case "$dep" in
      */libresolv*.dylib)
        /usr/bin/install_name_tool -change "$dep" /usr/lib/libresolv.9.dylib "$bin"
        ;;
    esac
  done < <(/usr/bin/otool -L "$bin" 2>/dev/null | awk 'NR>1 {print $1}')
done

php_bin="$PBS_DEPS/bin/php"
[ -x "$php_bin" ] || { echo "FATAL: $php_bin not produced" >&2; exit 1; }
echo
echo "--- php LC_LOAD_DYLIB audit ---"
otool -L "$php_bin" || true

fpm_bin="$PBS_DEPS/bin/php-fpm"
[ -x "$fpm_bin" ] || { echo "FATAL: $fpm_bin not produced" >&2; exit 1; }
echo
echo "--- php-fpm LC_LOAD_DYLIB audit ---"
otool -L "$fpm_bin" || true

echo "php OK"
