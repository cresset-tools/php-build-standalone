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
#   PBS_PHP_ICONV_ARG      — Linux: "--with-iconv=shared". Darwin: "--with-iconv=shared,$PBS_DEP_LIBICONV".
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
  --with-openssl="shared,$PBS_DEP_OPENSSL" \
  --with-libxml="$PBS_DEP_LIBXML2" \
  --enable-dom=shared \
  --enable-xml=shared \
  --enable-xmlreader=shared \
  --enable-xmlwriter=shared \
  --enable-simplexml=shared \
  --enable-mbstring=shared \
  --enable-mysqlnd \
  --with-mysqli="shared,mysqlnd" \
  --enable-pdo=shared \
  --with-pdo-mysql="shared,mysqlnd" \
  --with-pdo-sqlite="shared,$PBS_DEP_SQLITE" \
  --with-sqlite3="shared,$PBS_DEP_SQLITE" \
  --with-sodium="shared,$PBS_DEP_LIBSODIUM" \
  --with-bz2="shared,$PBS_DEP_BZIP2" \
  --with-curl="shared,$PBS_DEP_LIBCURL" \
  --enable-intl=shared \
  --with-zip=shared \
  --enable-gd=shared \
  --with-jpeg="$PBS_DEP_LIBJPEG_TURBO" \
  --with-webp="$PBS_DEP_LIBWEBP" \
  --with-freetype="$PBS_DEP_FREETYPE" \
  --enable-fileinfo=shared \
  --enable-filter=shared \
  --enable-phar=shared \
  --enable-posix=shared \
  --enable-session=shared \
  --enable-tokenizer=shared \
  --enable-ctype=shared \
  "$PBS_PHP_ICONV_ARG" \
  --with-libedit="$PBS_DEP_LIBEDIT" \
  --enable-opcache \
  PKG_CONFIG_PATH="$PBS_DEP_LIBZIP/lib/pkgconfig:$PBS_DEP_ICU/lib/pkgconfig:$PBS_DEP_LIBPNG/lib/pkgconfig:$PBS_DEP_LIBWEBP/lib/pkgconfig:$PBS_DEP_FREETYPE/lib/pkgconfig:$PBS_DEP_LIBJPEG_TURBO/lib/pkgconfig:$PBS_DEP_OPENSSL/lib/pkgconfig:$PBS_DEP_LIBCURL/lib/pkgconfig:$PBS_DEP_LIBXML2/lib/pkgconfig:$PBS_DEP_ONIGURUMA/lib/pkgconfig:$PBS_DEP_ZLIB/lib/pkgconfig:$PBS_DEP_SQLITE/lib/pkgconfig:$PBS_DEP_LIBSODIUM/lib/pkgconfig:$PBS_DEP_BZIP2/lib/pkgconfig:$PBS_DEP_NGHTTP2/lib/pkgconfig:$PBS_DEP_LIBEDIT/lib/pkgconfig:$PBS_DEP_NCURSES/lib/pkgconfig"

# Detoxify build-defs.h BEFORE compile. configure has just substituted
# /nix/store/<hash>-pbs-* paths into CONFIGURE_COMMAND, PHP_PREFIX,
# PHP_EXTENSION_DIR, PHP_CONFIG_FILE_PATH, etc. Compiling now would bake
# those raw store paths into bin/php's rodata, where they'd surface in
# `php -i` output ("Configure Command =>  ... '--prefix=/nix/store/...'").
# finalize-common.sh's text-file detoxify rewrites the *installed* header
# but the binary is already compiled by then.
#
# Same regex as common_detoxify_text_files — single source of truth for
# the sentinel-substitution pattern. Sentinel-substituting before compile
# means the binary's rodata, the installed header, and php-config all
# agree on /__PBS_PREFIX__, and the actual configure args (--enable-fpm,
# shared/static choices, every --with-* flag) stay visible in `php -i`.
sed -i -E 's|/nix/store/[a-z0-9]{32}-pbs-[^/[:space:]"'"'"']*|/__PBS_PREFIX__|g' main/build-defs.h

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

# Generate conf.d fragments for every always-shipped shared extension.
# Ordering ensures extensions are loaded after their dependencies:
#   10-* : zend_extensions (opcache) — must precede regular extensions
#   20-* : extensions with no cross-extension deps
#   30-* : pdo (driver extensions depend on it)
#   35-* : pdo_mysql, pdo_sqlite (depend on pdo)
#   40-* : mysqli, sqlite3 (depend on mysqlnd/libsqlite, not on pdo)
#   50-* : xmlreader, xmlwriter, simplexml (depend on dom being loaded)
mkdir -p "$PBS_DEPS/etc/php/conf.d"
_ini() { printf '%s\n' "$2" > "$PBS_DEPS/etc/php/conf.d/$1"; }
# PHP 8.5 made opcache always-static (built into bin/php); the
# --enable-opcache configure flag is ignored on that branch and no
# opcache.so is produced. Only emit the loader fragment if the .so
# actually exists, so 8.5 doesn't end up with a dangling reference.
ext_dir=$(find "$PBS_DEPS/lib/extensions" -maxdepth 1 -mindepth 1 -type d | head -n1)
if [ -n "$ext_dir" ] && [ -f "$ext_dir/opcache.so" ]; then
  _ini 10-opcache.ini    "zend_extension=opcache"
fi
_ini 20-mbstring.ini   "extension=mbstring"
_ini 20-intl.ini       "extension=intl"
_ini 20-curl.ini       "extension=curl"
_ini 20-sodium.ini     "extension=sodium"
_ini 20-bz2.ini        "extension=bz2"
_ini 20-zip.ini        "extension=zip"
_ini 20-gd.ini         "extension=gd"
_ini 20-fileinfo.ini   "extension=fileinfo"
_ini 20-filter.ini     "extension=filter"
_ini 20-phar.ini       "extension=phar"
_ini 20-posix.ini      "extension=posix"
_ini 20-session.ini    "extension=session"
_ini 20-tokenizer.ini  "extension=tokenizer"
_ini 20-ctype.ini      "extension=ctype"
_ini 20-iconv.ini      "extension=iconv"
_ini 20-openssl.ini    "extension=openssl"
_ini 20-xml.ini        "extension=xml"
_ini 20-dom.ini        "extension=dom"
_ini 30-pdo.ini        "extension=pdo"
_ini 35-pdo_mysql.ini  "extension=pdo_mysql"
_ini 35-pdo_sqlite.ini "extension=pdo_sqlite"
_ini 40-mysqli.ini     "extension=mysqli"
_ini 40-sqlite3.ini    "extension=sqlite3"
_ini 50-xmlreader.ini  "extension=xmlreader"
_ini 50-xmlwriter.ini  "extension=xmlwriter"
_ini 50-simplexml.ini  "extension=simplexml"

# Confirm readline (libedit-backed) is compiled into the binary. PHP
# builds ext/readline statically into the CLI (no readline.so), so we
# verify via php -m rather than looking for an extension .so file.
if ! env "$PBS_RPATH_VAR=$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" "$PBS_DEPS/bin/php" -m | grep -qi readline; then
  echo "FATAL: readline not listed in php -m; --with-libedit configure step may have silently failed" >&2
  exit 1
fi
echo "readline OK (libedit-backed)"

# Verify every always-shipped extension loads. Uses `php -m` which picks
# up conf.d fragments generated above. Failure names the missing extension
# explicitly so it's easy to bisect from build logs.
_php_m=$(env "$PBS_RPATH_VAR=$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" "$PBS_DEPS/bin/php" -m 2>&1)
_check_ext() {
  local ext="$1"
  if ! printf '%s\n' "$_php_m" | grep -qi "^${ext}$"; then
    echo "FATAL: always-shipped extension '$ext' not listed in php -m" >&2
    echo "       php -m output:" >&2
    printf '%s\n' "$_php_m" >&2
    exit 1
  fi
}
for _ext in mbstring intl curl pdo pdo_mysql pdo_sqlite sqlite3 sodium \
            bz2 zip gd fileinfo filter phar posix session tokenizer \
            ctype iconv dom xml xmlreader xmlwriter simplexml mysqli \
            openssl; do
  _check_ext "$_ext"
  echo "  ext OK: $_ext"
done
echo "all always-shipped extensions OK"

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
