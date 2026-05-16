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
: "${PBS_DEP_LIBXSLT:?}"
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
: "${PBS_DEP_LIBPQ:?}"
: "${PBS_DEP_LIBGMP:?}"
: "${PBS_DEP_LIBFFI:?}"
: "${PBS_PHP_PRE_CONFIGURE:?set by php.nix}"
: "${PBS_PHP_POST_INSTALL:?set by php.nix}"
: "${PBS_PHP_AUDIT_EXTRA:?set by php.nix}"
: "${PBS_PHP_ICONV_ARG:?set by php.nix}"
: "${PBS_PHP_GETTEXT_ARG:?set by php.nix}"

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
  --with-xsl="shared,$PBS_DEP_LIBXSLT" \
  --enable-dom=shared \
  --enable-xml=shared \
  --enable-xmlreader=shared \
  --enable-xmlwriter=shared \
  --enable-simplexml=shared \
  --enable-mbstring=shared \
  --enable-mysqlnd=shared \
  --with-mysqli="shared,mysqlnd" \
  --enable-pdo=shared \
  --with-pdo-mysql="shared,mysqlnd" \
  --with-pdo-sqlite="shared,$PBS_DEP_SQLITE" \
  --with-sqlite3="shared,$PBS_DEP_SQLITE" \
  --with-pgsql="shared,$PBS_DEP_LIBPQ" \
  --with-pdo-pgsql="shared,$PBS_DEP_LIBPQ" \
  --with-sodium="$PBS_DEP_LIBSODIUM" \
  --with-bz2="shared,$PBS_DEP_BZIP2" \
  --with-curl="shared,$PBS_DEP_LIBCURL" \
  --enable-intl=shared \
  --with-zip=shared \
  --enable-gd=shared \
  --with-jpeg="$PBS_DEP_LIBJPEG_TURBO" \
  --with-webp="$PBS_DEP_LIBWEBP" \
  --with-freetype="$PBS_DEP_FREETYPE" \
  --enable-exif=shared \
  --enable-fileinfo=shared \
  --enable-filter \
  --enable-phar=shared \
  --enable-posix=shared \
  --enable-session \
  --enable-tokenizer=shared \
  --enable-ctype=shared \
  --enable-bcmath=shared \
  --enable-calendar=shared \
  --enable-ftp=shared \
  --enable-pcntl \
  --enable-shmop=shared \
  --enable-sockets=shared \
  --enable-sysvmsg=shared \
  --enable-sysvsem=shared \
  --enable-sysvshm=shared \
  --enable-soap=shared \
  --with-gmp="shared,$PBS_DEP_LIBGMP" \
  "$PBS_PHP_ICONV_ARG" \
  "${PBS_PHP_GETTEXT_ARG//__PBS_SYSROOT__/${PBS_SYSROOT:-/dev/null}}" \
  --with-libedit="shared,$PBS_DEP_LIBEDIT" \
  --with-ffi=shared \
  --enable-opcache \
  PKG_CONFIG_PATH="$PBS_DEP_LIBZIP/lib/pkgconfig:$PBS_DEP_ICU/lib/pkgconfig:$PBS_DEP_LIBPNG/lib/pkgconfig:$PBS_DEP_LIBWEBP/lib/pkgconfig:$PBS_DEP_FREETYPE/lib/pkgconfig:$PBS_DEP_LIBJPEG_TURBO/lib/pkgconfig:$PBS_DEP_OPENSSL/lib/pkgconfig:$PBS_DEP_LIBCURL/lib/pkgconfig:$PBS_DEP_LIBXML2/lib/pkgconfig:$PBS_DEP_LIBXSLT/lib/pkgconfig:$PBS_DEP_ONIGURUMA/lib/pkgconfig:$PBS_DEP_ZLIB/lib/pkgconfig:$PBS_DEP_SQLITE/lib/pkgconfig:$PBS_DEP_LIBSODIUM/lib/pkgconfig:$PBS_DEP_BZIP2/lib/pkgconfig:$PBS_DEP_NGHTTP2/lib/pkgconfig:$PBS_DEP_LIBEDIT/lib/pkgconfig:$PBS_DEP_NCURSES/lib/pkgconfig:$PBS_DEP_LIBPQ/lib/pkgconfig:$PBS_DEP_LIBFFI/lib/pkgconfig"

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

# No conf.d generation: the interpreter tarball ships zero auto-loading
# fragments (REFACTOR_DEBIAN_ALIGNED.md). Each per-ext tarball emits its
# own conf.d/*.ini at consumer-install time, so the bare interpreter starts
# with the Debian-faithful static set only.
ext_dir=$(find "$PBS_DEPS/lib/extensions" -maxdepth 1 -mindepth 1 -type d | head -n1)
[ -n "$ext_dir" ] || { echo "FATAL: no lib/extensions/<api>/ produced" >&2; exit 1; }

# Bare-interpreter assertion: php -m on bin/php (no -d flags, no conf.d)
# must show the Debian-faithful static set — and must NOT show any of the
# extensions that should now ship only as per-ext tarballs. Required +
# forbidden sets, not strict equality, so version-specific modules (random
# is 8.2+; opcache is static on 8.5) don't trip the check.
bare_modules=$(env "$PBS_RPATH_VAR=$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" \
                 "$PBS_DEPS/bin/php" -n -m 2>&1)
# Required: every Debian-php8.2-cli static module that exists in every
# supported PHP minor (8.1–8.5). `Core` is omitted by ext/standard's
# modules table on every PHP, so it's not checkable here.
for _req in Reflection SPL date filter hash json libxml openssl \
            pcntl pcre session sodium standard zlib; do
  if ! printf '%s\n' "$bare_modules" | grep -qE "^${_req}$"; then
    echo "FATAL: required static module '$_req' missing from bare php -m" >&2
    printf '%s\n' "$bare_modules" >&2
    exit 1
  fi
done
# Forbidden: any module that should ship only as a per-ext tarball must
# NOT appear in the bare interpreter's php -m. If one does, a configure
# flag flip got reverted or a static-by-default got missed.
for _fbd in ctype iconv mbstring intl curl gd fileinfo phar posix \
            tokenizer pdo dom mysqli mysqlnd sqlite3 readline ffi \
            bcmath calendar ftp exif bz2 zip shmop soap sockets \
            sysvmsg sysvsem sysvshm gmp pgsql xmlreader xmlwriter \
            SimpleXML xsl; do
  if printf '%s\n' "$bare_modules" | grep -qE "^${_fbd}$"; then
    echo "FATAL: forbidden module '$_fbd' present in bare php -m (should be per-ext only)" >&2
    printf '%s\n' "$bare_modules" >&2
    exit 1
  fi
done
echo "bare interpreter php -m matches Debian-faithful static set"

# Canonical readline check (spec §"Two consequences worth being explicit"):
# `php -a` on the bare interpreter must error with the Debian-equivalent
# message because readline.so is no longer loaded by default. This is the
# explicit positive proof that the interpreter tarball alone is *less*
# than apt install php8.2-cli.
readline_err=$(env "$PBS_RPATH_VAR=$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" \
                 "$PBS_DEPS/bin/php" -n -a < /dev/null 2>&1 || true)
if ! printf '%s\n' "$readline_err" | grep -qi "readline"; then
  echo "FATAL: php -a did not complain about missing readline" >&2
  echo "       output: $readline_err" >&2
  exit 1
fi
echo "php -a → readline-required error (Debian-equivalent)"

# Per-ext .so ad-hoc load test: each shared extension built by configure
# must load cleanly on its own when force-loaded against the bare
# interpreter. Catches missing DT_NEEDED entries, ABI mismatches, or
# extensions that lost their --enable-X=shared flag.
#
# Some extensions require another module to be loaded first:
#   mysqli, pdo_mysql require mysqlnd
#   pdo_mysql, pdo_sqlite, pdo_pgsql require pdo
#   xmlreader, xmlwriter, simplexml require dom (and dom requires libxml)
# We pass multiple -d extension= flags in dependency order for those.
_load_test() {
  local probe_name="$1"; shift
  local args=()
  for so in "$@"; do
    case "$so" in
      opcache) args+=(-d "zend_extension=$ext_dir/$so.so") ;;
      *)       args+=(-d "extension=$ext_dir/$so.so") ;;
    esac
  done
  if ! env "$PBS_RPATH_VAR=$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" \
       "$PBS_DEPS/bin/php" -n "${args[@]}" -m 2>&1 | grep -qiE "^${probe_name}$"; then
    echo "FATAL: ad-hoc load failed for $probe_name (loaded: $*)" >&2
    env "$PBS_RPATH_VAR=$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" \
       "$PBS_DEPS/bin/php" -n "${args[@]}" -m >&2 || true
    exit 1
  fi
  echo "  ad-hoc load OK: $probe_name"
}

# Standalone extensions (no required dep beyond what bin/php already has).
# openssl/sodium are now statically linked into bin/php — no .so emitted.
# filter/session/pcntl likewise. Those don't appear here.
for _ext in mbstring intl curl bz2 zip gd exif bcmath calendar ftp \
            shmop sockets sysvmsg sysvsem sysvshm gmp fileinfo phar posix \
            tokenizer ctype iconv xml dom pdo pgsql sqlite3 soap \
            ffi mysqlnd; do
  _load_test "$_ext" "$_ext"
done
# Dependent extensions: load required modules first.
_load_test "mysqli"     mysqlnd mysqli
_load_test "pdo_mysql"  pdo mysqlnd pdo_mysql
_load_test "pdo_sqlite" pdo pdo_sqlite
_load_test "pdo_pgsql"  pdo pdo_pgsql
_load_test "xmlreader"  dom xmlreader
_load_test "xmlwriter"  dom xmlwriter
_load_test "SimpleXML"  dom simplexml
_load_test "xsl"        dom xsl
# readline.so replaces the previously-static ext/readline. Verify it loads.
_load_test "readline"   readline
# opcache: zend_extension on 8.1–8.4, static on 8.5 (then no .so exists).
if [ -f "$ext_dir/opcache.so" ]; then
  _load_test "Zend OPcache" opcache
fi
# gettext is Linux-only; build-php.sh produces gettext.so only there.
if [ -f "$ext_dir/gettext.so" ]; then
  _load_test "gettext" gettext
fi
echo "all per-ext ad-hoc loads OK"

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
