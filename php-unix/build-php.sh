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
# only the LSB-standard glibc set on x86_64; we match that. Three flag
# changes vs the default CC composition in setup-env.sh:
#
# (1) Drop -Wl,--copy-dt-needed-entries. That flag is essential for
#     libtool's testdso/xmlcatalog rules in libxml2, but with a static
#     C++ runtime present (see (3)) it produces versym entries with
#     empty version names — the binary then dies at startup with
#     "no version information available (required by .../php)". PHP's
#     own link line is well-behaved (every needed lib is named via -l),
#     so the flag isn't needed here.
#
# (2) Use -Wl,--as-needed (NOT --no-as-needed). With --as-needed, when
#     libtool re-adds -lstdc++ at the end of the link line, the linker
#     emits a DT_NEEDED only if some symbol is still unresolved — which
#     won't happen, because libstdc++.a (3) already resolved everything.
#     --no-as-needed (our default) would force a DT_NEEDED libstdc++.so.6
#     even though the static archive made it redundant.
#
# (3) Static-link libstdc++ via the .a file as a positional LDFLAG.
#     -static-libstdc++ is a g++ driver flag and PHP's link runs through
#     gcc, so we go direct: pass libstdc++.a as a positional argument so
#     the linker resolves C++ symbols from it before any later -lstdc++.
#     gcc-unwrapped's main /lib is where the .a lives — not on our search
#     path by default, so we ask gcc itself for the path.
#
# (4) -static-libgcc baked into CC so it applies to every gcc invocation,
#     including the tiny build-time helpers under ext/opcache/jit/ir/
#     (gen_ir_fold_hash, minilua) which don't pick up our LDFLAGS and
#     would otherwise fail with "cannot find -lgcc_s".
gcc_libstdcxx_a="$(gcc -print-file-name=libstdc++.a)"
if [ ! -f "$gcc_libstdcxx_a" ]; then
  echo "FATAL: gcc -print-file-name=libstdc++.a returned non-existent path: $gcc_libstdcxx_a" >&2
  exit 1
fi
export CC="gcc -B${PBS_GLIBC_LIB} -Wl,--as-needed -static-libgcc"
export CXX="g++ -B${PBS_GLIBC_LIB} -Wl,--as-needed -static-libgcc"
export LDFLAGS="$LDFLAGS ${gcc_libstdcxx_a}"

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
  --disable-rpath \
  --disable-cgi \
  --disable-phpdbg \
  --enable-cli \
  --enable-fpm \
  --without-pear \
  --with-config-file-path="$PBS_DEPS/etc" \
  --with-config-file-scan-dir="$PBS_DEPS/etc/conf.d" \
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
  --without-iconv \
  --enable-opcache \
  PKG_CONFIG_PATH="$PBS_DEP_LIBZIP/lib/pkgconfig:$PBS_DEP_ICU/lib/pkgconfig:$PBS_DEP_LIBPNG/lib/pkgconfig:$PBS_DEP_LIBWEBP/lib/pkgconfig:$PBS_DEP_FREETYPE/lib/pkgconfig:$PBS_DEP_LIBJPEG_TURBO/lib/pkgconfig:$PBS_DEP_OPENSSL/lib/pkgconfig:$PBS_DEP_LIBCURL/lib/pkgconfig:$PBS_DEP_LIBXML2/lib/pkgconfig:$PBS_DEP_ONIGURUMA/lib/pkgconfig:$PBS_DEP_ZLIB/lib/pkgconfig:$PBS_DEP_SQLITE/lib/pkgconfig:$PBS_DEP_LIBSODIUM/lib/pkgconfig:$PBS_DEP_BZIP2/lib/pkgconfig:$PBS_DEP_NGHTTP2/lib/pkgconfig"

# PHP's build is single-pass; no separate libs/exec phases.
make -j"$(nproc)"

# `make install` writes everything (binaries + extensions + headers +
# build files + man pages) under $PBS_DEPS=$out.
make install

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
