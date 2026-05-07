#!/usr/bin/env bash
# Build PHP itself: php (CLI), php-fpm, phpize/php-config, extension
# .so/.dylib files, and headers/build files for downstream PECL builds.
#
# This script is OS-agnostic. Platform-specific steps are sourced from
# Nix-provided snippet paths:
#   PBS_PHP_PRE_CONFIGURE  — Linux: libstdc++.a + --as-needed CC override.
#                            Darwin: libresolv setup + iconv autoconf priming.
#   PBS_PHP_POST_INSTALL   — Linux: noop. Darwin: rewrite libresolv install_name.
#   PBS_PHP_AUDIT_EXTRA    — Linux: DT_NEEDED bare-soname check. Darwin: noop.
#   PBS_PHP_ICONV_ARG      — Linux: "--with-iconv". Darwin: "--with-iconv=$PBS_DEP_LIBICONV".
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env-{linux,darwin}.sh; mkDep.nix
# auto-appends -I${dep}/include and -L${dep}/lib for every dep on our
# `deps` list, plus exports PBS_DEP_<NAME> for the deps wired by path.

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
: "${PBS_PHP_PRE_CONFIGURE:?set by php.nix}"
: "${PBS_PHP_POST_INSTALL:?set by php.nix}"
: "${PBS_PHP_AUDIT_EXTRA:?set by php.nix}"
: "${PBS_PHP_ICONV_ARG:?set by php.nix}"

src_dir="$PBS_SOURCES/php-${PBS_VER_PHP}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_PHP" -C "$PBS_SOURCES"
cd "$src_dir"

# Apply patches BEFORE configure runs — phpize.in / php-config.in are
# inputs to configure (it substitutes @prefix@ etc).
bash "${PBS_PHP_PREPARE_SCRIPT}"

# ICU 75's headers require C++17. PHP 8.4+ already defaults to C++17,
# but 8.1/8.2/8.3 default to C++11 and the intl extension fails to
# compile against ICU 75 unless we bump CXXFLAGS. Setting -std=c++17
# unconditionally is a no-op on 8.4+ and load-bearing on the older
# minors.
export CXXFLAGS="${CXXFLAGS:-} -std=c++17"

# Platform-specific pre-configure setup (libstdc++.a positional vs
# libresolv + iconv cache priming).
source "$PBS_PHP_PRE_CONFIGURE"

# PHP's configure links against host system libs in some optional paths.
# We've already passed -L flags via LDFLAGS for every dep; the explicit
# --with-<lib>=$DEP further tells PHP to search $DEP/include and
# $DEP/lib for that library specifically. Belt-and-braces.
#
# Extension scope: minimal core + DB + curl + intl + gd, matching the
# v1 plan (CLAUDE.md). Most listed-but-not-flagged extensions are
# default-on (ctype, date, fileinfo, hash, pcre, reflection, spl).
#
# SAPIs: CLI + FPM only. CGI and phpdbg explicitly disabled.
#
# --disable-rpath: PHP's configure auto-appends -R $libdir to LDFLAGS
#   for each --with-<lib> path. That bakes /nix/store paths into RPATHs.
#   Easier and cleaner to never emit them in the first place.
#
# --without-pear: pear is deprecated and bakes PHP_PEAR_INSTALL_DIR
#   into shebangs at install time, leaking the /nix/store prefix.
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
  "$PBS_PHP_ICONV_ARG" \
  --with-libedit="$PBS_DEP_LIBEDIT" \
  --enable-opcache \
  PKG_CONFIG_PATH="$PBS_DEP_LIBZIP/lib/pkgconfig:$PBS_DEP_ICU/lib/pkgconfig:$PBS_DEP_LIBPNG/lib/pkgconfig:$PBS_DEP_LIBWEBP/lib/pkgconfig:$PBS_DEP_FREETYPE/lib/pkgconfig:$PBS_DEP_LIBJPEG_TURBO/lib/pkgconfig:$PBS_DEP_OPENSSL/lib/pkgconfig:$PBS_DEP_LIBCURL/lib/pkgconfig:$PBS_DEP_LIBXML2/lib/pkgconfig:$PBS_DEP_ONIGURUMA/lib/pkgconfig:$PBS_DEP_ZLIB/lib/pkgconfig:$PBS_DEP_SQLITE/lib/pkgconfig:$PBS_DEP_LIBSODIUM/lib/pkgconfig:$PBS_DEP_BZIP2/lib/pkgconfig:$PBS_DEP_NGHTTP2/lib/pkgconfig:$PBS_DEP_LIBEDIT/lib/pkgconfig:$PBS_DEP_NCURSES/lib/pkgconfig"

# $PBS_RPATH_VAR is LD_LIBRARY_PATH on Linux, DYLD_LIBRARY_PATH on Darwin.
# ext/phar/Makefile.frag's pharcmd target invokes the freshly-built
# sapi/cli/php to generate ext/phar/phar.php and phar.phar via
# build_precommand.php. That binary has DT_NEEDED for libssl.so.3,
# libicuio.so.75 etc. with bare sonames; without runtime search-path
# wiring it fails with "libssl.so.3: cannot open shared object file" —
# and the Makefile's `-@` prefix swallows the error silently, leaving
# install-pharcmd to create bin/phar -> phar.phar as a dangling symlink.
# pharcmd is part of the default `all` target, so we need this on
# `make` too, not just `make install`.
env "$PBS_RPATH_VAR=${PBS_DEPS_LDPATH:-}" make -j"$NIX_BUILD_CORES"
env "$PBS_RPATH_VAR=${PBS_DEPS_LDPATH:-}" make install

# Sanity: install-pharcmd's `-@` prefix means a failed phar.phar build
# never propagates a non-zero exit. Verify the file actually landed.
if [ ! -f "$PBS_DEPS/bin/phar.phar" ]; then
  echo "FATAL: bin/phar.phar not produced; pharcmd likely failed silently (check $PBS_RPATH_VAR)" >&2
  exit 1
fi

# Confirm readline (libedit-backed) is compiled into the binary. PHP
# builds ext/readline statically into the CLI (no readline.so), so we
# verify via php -m rather than looking for an extension .so file.
if ! env "$PBS_RPATH_VAR=$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" "$PBS_DEPS/bin/php" -m | grep -qi readline; then
  echo "FATAL: readline not listed in php -m; --with-libedit configure step may have silently failed" >&2
  exit 1
fi
echo "readline OK (libedit-backed)"

# Sanity: a request-bearing run (script file argument) must shut down
# cleanly. The 0004-relocate-extension-dir-startup patch has historically
# broken request shutdown by populating EG(modified_ini_directives) at
# MINIT, which then segfaults in zend_ini_deactivate. `php -v` and `php -m`
# bypass the request lifecycle and miss this; `php script.php` exercises it.
sanity_script="$(mktemp)"
printf '<?php echo "ok\\n";\n' > "$sanity_script"
sanity_out=$(env "$PBS_RPATH_VAR=$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" "$PBS_DEPS/bin/php" -n "$sanity_script" 2>&1)
sanity_rc=$?
rm -f "$sanity_script"
if [ "$sanity_rc" -ne 0 ] || [ "$sanity_out" != "ok" ]; then
  echo "FATAL: php script.php exited rc=$sanity_rc with output: $sanity_out" >&2
  echo "       (rc=139 indicates the zend_ini_deactivate regression — see patches/0004-relocate-extension-dir-startup)" >&2
  exit 1
fi
echo "request shutdown OK"

# PHP's install drops a few things we don't need or that bake build-time
# paths and would fail the audit:
#   - share/man/    — references build-time prefix in some places
#   - lib/php/test/ — test fixtures; not consumed by PHP at runtime
rm -rf "$PBS_DEPS/share/man"
rm -rf "$PBS_DEPS/lib/php/test"

# Platform post-install (Darwin: libresolv install_name rewrite; Linux:
# noop).
source "$PBS_PHP_POST_INSTALL"

# Sanity: php + php-fpm exist and pass the audit. pbs_audit_lib also
# enforces no /nix/store leak on Linux DT_NEEDED.
php_bin="$PBS_DEPS/bin/php"
[ -x "$php_bin" ] || { echo "FATAL: $php_bin not produced" >&2; exit 1; }
pbs_audit_lib "$php_bin" php

fpm_bin="$PBS_DEPS/bin/php-fpm"
[ -x "$fpm_bin" ] || { echo "FATAL: $fpm_bin not produced" >&2; exit 1; }
pbs_audit_lib "$fpm_bin" php-fpm

# Platform extra audit (Linux: bare-DT_NEEDED check; Darwin: noop).
source "$PBS_PHP_AUDIT_EXTRA"

echo "php OK"
