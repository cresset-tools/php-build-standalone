#!/usr/bin/env bash
# Build PHP itself: php (CLI), php-fpm, phpize/php-config helper scripts,
# extension .so files, and headers/build files for downstream PECL builds.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh; mkDep.nix has already
# auto-appended -I${dep}/include and -L${dep}/lib for every dep on our
# `deps` list, plus exported PBS_DEP_<NAME> for the deps we wire by path.
#
# Each --with-<lib>=<path> below points at one of the bundled deps' /nix/
# store $out (the immutable build-time location). The resulting binaries
# DT_NEEDED bare sonames; finalize.sh rewrites RPATHs to $ORIGIN/../lib
# at tree-merge time so the tarball is relocatable.

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

src_dir="$PBS_SOURCES/php-${PBS_VER_PHP}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_PHP" -C "$PBS_SOURCES"
cd "$src_dir"

# Apply patches BEFORE configure runs — phpize.in / php-config.in are
# inputs to configure (it substitutes @prefix@ etc).
bash "${PBS_PHP_PREPARE_SCRIPT}"

# PBS-equivalent C runtime story for PHP itself: don't bundle
# libstdc++.so.6 / libgcc_s.so.1 in the tarball. PBS's validator allows
# only the LSB-standard glibc set on x86_64; we match that.
#
# Two changes vs the default CC composition in setup-env.sh:
#
# (1) Use -Wl,--as-needed (overriding setup-env.sh's --no-as-needed).
#     When libtool re-adds -lstdc++ at the end of the PHP link line, we
#     want the linker to emit a DT_NEEDED only if some C++ symbol is
#     still unresolved — which won't happen, because libstdc++.a (2)
#     already resolved everything. --no-as-needed would force a
#     DT_NEEDED libstdc++.so.6 even though the static archive made it
#     redundant. (Our wrapper already passes -static-libgcc, so libgcc
#     is fine without this dance.)
#
# (2) Static-link libstdc++ via libstdc++.a as a positional LDFLAG.
#     -static-libstdc++ is a clang++ driver flag and PHP's link runs
#     through cc (clang via our wrapper), so we go direct: pass
#     libstdc++.a as a positional argument so the linker resolves C++
#     symbols from it before any later -lstdc++. The archive is in
#     our sysroot, copied there by sysroot.nix from devtoolset-11.
libstdcxx_a="${PBS_SYSROOT}/usr/lib64/libstdc++.a"
if [ ! -f "$libstdcxx_a" ]; then
  echo "FATAL: $libstdcxx_a not present in sysroot" >&2
  exit 1
fi
export CC="${PBS_TOOLCHAIN}/bin/cc -Wl,--as-needed"
export CXX="${PBS_TOOLCHAIN}/bin/c++ -Wl,--as-needed"
export LDFLAGS="$LDFLAGS ${libstdcxx_a}"

# ICU 75's headers require C++17. PHP 8.4+ already defaults to C++17, but
# 8.1 / 8.2 / 8.3 default to C++11 and the intl extension fails to compile
# against ICU 75 unless we bump CXXFLAGS. Setting -std=c++17 unconditionally
# is a no-op on 8.4/8.5 and load-bearing on the older minors. PHP's configure
# threads CXXFLAGS into intl's Makefile.
export CXXFLAGS="${CXXFLAGS:-} -std=c++17"

# PHP's configure links against host system libs in some optional paths.
# We've already passed -L flags via LDFLAGS for every dep; the explicit
# --with-<lib>=$DEP further tells PHP to search $DEP/include and $DEP/lib
# for that library specifically. Belt-and-braces — autodetection should
# find them through CFLAGS/LDFLAGS, but explicit dep-paths short-circuit
# any host-system fallback.
#
# Extension scope: minimal core + DB + curl + intl + gd, matching the v1
# plan (CLAUDE.md). Most of the listed-but-not-flagged extensions are
# default-on (e.g. ctype, date, fileinfo, hash, pcre, reflection, spl).
#
# SAPIs: CLI + FPM only. CGI and phpdbg are explicitly disabled — fewer
# binaries to finalize, fewer files to ship.
#
# --disable-rpath: PHP's configure auto-appends -R $libdir to LDFLAGS for
#   each --with-<lib> path. That bakes /nix/store paths into RPATHs, which
#   finalize.sh would then patchelf away — but easier and cleaner to never
#   emit them in the first place. Our explicit --disable-new-dtags +
#   patchelf at finalize gives us deterministic $ORIGIN-relative RPATHs.
#
# --without-pear: pear is deprecated and bakes PHP_PEAR_INSTALL_DIR into
#   shebangs at install time, which leaks the /nix/store prefix.
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
  --with-iconv \
  --with-libedit="$PBS_DEP_LIBEDIT" \
  --enable-opcache \
  PKG_CONFIG_PATH="$PBS_DEP_LIBZIP/lib/pkgconfig:$PBS_DEP_ICU/lib/pkgconfig:$PBS_DEP_LIBPNG/lib/pkgconfig:$PBS_DEP_LIBWEBP/lib/pkgconfig:$PBS_DEP_FREETYPE/lib/pkgconfig:$PBS_DEP_LIBJPEG_TURBO/lib/pkgconfig:$PBS_DEP_OPENSSL/lib/pkgconfig:$PBS_DEP_LIBCURL/lib/pkgconfig:$PBS_DEP_LIBXML2/lib/pkgconfig:$PBS_DEP_ONIGURUMA/lib/pkgconfig:$PBS_DEP_ZLIB/lib/pkgconfig:$PBS_DEP_SQLITE/lib/pkgconfig:$PBS_DEP_LIBSODIUM/lib/pkgconfig:$PBS_DEP_BZIP2/lib/pkgconfig:$PBS_DEP_NGHTTP2/lib/pkgconfig:$PBS_DEP_LIBEDIT/lib/pkgconfig:$PBS_DEP_NCURSES/lib/pkgconfig"

# PHP's build is single-pass; no separate libs/exec phases.
#
# LD_LIBRARY_PATH: ext/phar/Makefile.frag's pharcmd target invokes the
# freshly-built sapi/cli/php to generate ext/phar/phar.php and phar.phar
# via build_precommand.php. That binary has DT_NEEDED for libssl.so.3,
# libicuio.so.75, etc. with bare sonames, and at this stage its DT_RPATH
# only covers a subset of bundled deps (some pkg-config-resolved deps
# slip in via libtool, others don't). Without LD_LIBRARY_PATH it fails
# with "libssl.so.3: cannot open shared object file" — and the
# Makefile's `-@` prefix swallows the error silently, leaving install-
# pharcmd to create bin/phar -> phar.phar as a dangling symlink.
# pharcmd is part of the default `all` target, so we need this on `make`
# too, not just `make install`.
LD_LIBRARY_PATH="${PBS_DEPS_LDPATH:-}" make -j"$(nproc)"

# `make install` writes everything (binaries + extensions + headers +
# build files + man pages) under $PBS_DEPS=$out. LD_LIBRARY_PATH is
# kept here for the same reason — install-pharcmd re-invokes the cli
# binary if phar.phar is missing.
LD_LIBRARY_PATH="${PBS_DEPS_LDPATH:-}" make install

# Sanity: install-pharcmd's `-@` prefix means a failed phar.phar build
# never propagates a non-zero exit. Verify the file actually landed.
if [ ! -f "$PBS_DEPS/bin/phar.phar" ]; then
  echo "FATAL: bin/phar.phar not produced; pharcmd likely failed silently (check LD_LIBRARY_PATH)" >&2
  exit 1
fi

# Confirm readline (libedit-backed) is compiled into the binary. PHP builds
# ext/readline statically into the CLI (no readline.so), so we verify via
# php -m rather than looking for an extension .so file.
# We need LD_LIBRARY_PATH so the just-built php can find its bundled shared
# libs (libssl, libedit, etc.) at this point — they are in our dep store
# paths which PBS_DEPS_LDPATH accumulates across all deps. This is safe
# here because we scope it to a single command, not the whole build script.
if ! LD_LIBRARY_PATH="$PBS_DEPS/lib${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}" "$PBS_DEPS/bin/php" -m | grep -qi readline; then
  echo "FATAL: readline not listed in php -m; --with-libedit configure step may have silently failed" >&2
  exit 1
fi
echo "readline OK (libedit-backed)"

# PHP's install drops a few things we don't need or that bake build-time
# paths and would fail the audit:
#   - share/man/    — man pages reference build-time prefix in some places
#                     and are dead weight for a portable runtime.
#   - lib/php/test/ — test fixtures; not consumed by PHP at runtime.
rm -rf "$PBS_DEPS/share/man"
rm -rf "$PBS_DEPS/lib/php/test"

# Sanity: php binary must exist with NEEDED entries we recognize.
php_bin="$PBS_DEPS/bin/php"
if [ ! -x "$php_bin" ]; then
  echo "FATAL: $php_bin not produced" >&2
  exit 1
fi
echo
echo "--- php NEEDED audit ---"
needed=$(readelf -d "$php_bin" | grep NEEDED || true)
echo "$needed"
# Bare sonames only — our LDFLAGS/-l shape produces these. Anything with
# a / in it would be a build-bug we'd want to know about now.
if echo "$needed" | grep -E 'NEEDED.*\[/' ; then
  echo "FATAL: php has absolute path in DT_NEEDED" >&2
  exit 1
fi

echo
echo "--- php-fpm NEEDED audit ---"
fpm_bin="$PBS_DEPS/bin/php-fpm"
if [ ! -x "$fpm_bin" ]; then
  echo "FATAL: $fpm_bin not produced" >&2
  exit 1
fi
readelf -d "$fpm_bin" | grep NEEDED || true

echo "php OK"
