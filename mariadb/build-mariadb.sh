#!/usr/bin/env bash
# Build MariaDB (mariadbd + clients + libmariadb) into ${PBS_DEPS}.
#
# CMake invocation uses INSTALL_LAYOUT=STANDALONE so the install tree is
# self-contained: bin/, lib/, lib/plugin/, include/mariadb/, share/mariadb/.
# mariadbd resolves its basedir from argv[0] at runtime, so the whole tree
# stays portable as long as bin/ and share/mariadb/ remain siblings.
#
# RPATH is set to $ORIGIN/../lib (Linux) / @loader_path/../lib (Darwin) so
# the bundled OpenSSL / zlib / ncurses resolve via the install-tree's own
# lib/ rather than the system path. finalize-{linux,darwin}.sh runs after
# install and re-asserts RPATHs across the merged tree.
#
# Plugin selection: keep InnoDB (default), Aria, MyISAM, CSV, MEMORY, and
# the auth/authentication plugins. Skip the heavyweight optional engines
# (RocksDB, Mroonga, ColumnStore, Spider, S3, Connect) — every one of
# them needs at least one extra C library dep we don't currently ship,
# and most are niche enough to belong in an "extensions" channel rather
# than the default server bundle.

set -euo pipefail

: "${PBS_SRC_MARIADB:?}"
: "${PBS_VER_MARIADB:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?}"
: "${PBS_DEP_OPENSSL:?}"
: "${PBS_DEP_NCURSES:?}"
: "${PBS_DEP_LIBEDIT:?}"
: "${PBS_DEP_PCRE2:?}"
: "${PBS_SRC_LIBFMT:?}"

# MariaDB's bundled PCRE2 path triggers an ExternalProject_Add download
# at CMake-configure time, which fails inside the Nix sandbox (no network).
# Point pkg-config at our pre-built pcre2 so WITH_PCRE=system / WITH_PCRE2
# detection finds it locally.
export PKG_CONFIG_PATH="$PBS_DEP_PCRE2/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

src_dir="$PBS_SOURCES/mariadb-${PBS_VER_MARIADB}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_MARIADB" -C "$PBS_SOURCES"
cd "$src_dir"

# client/mysql.cc has a hard `#ifdef __APPLE__ #include <editline/readline.h>`
# shortcut that bypasses cmake/readline.cmake's MY_READLINE_INCLUDE_DIR. We
# point LIBEDIT_INCLUDE_DIR at $PBS_DEP_LIBEDIT/include/editline (the Debian-
# style layout MariaDB's libedit probe expects: it test-compiles
# `#include <readline.h>` against that dir). The __APPLE__ branch would need
# the parent $PBS_DEP_LIBEDIT/include on the include path instead, which
# isn't there — so on Darwin it can't find the header and the compile fails.
# Drop the Apple-only branch and let mysql.cc use the same `#include
# <readline.h>` path Linux does, which resolves via MY_READLINE_INCLUDE_DIR.
# Idempotent: matches only the Apple branch.
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  perl -i -0pe 's{# ifdef __APPLE__\n#  include <editline/readline\.h>\n# else\n(#  include <readline\.h>\n#  if !defined\(USE_LIBEDIT_INTERFACE\)\n#   include <history\.h>\n#  endif\n)# endif\n}{$1}' client/mysql.cc
  grep -q 'editline/readline.h' client/mysql.cc && { echo "FATAL: mysql.cc __APPLE__ readline patch did not apply" >&2; exit 1; } || true
fi

# Neutralize the bundled libmariadb FindZStd.cmake. MariaDB's libmariadb
# auto-detects host zstd via INCLUDE(cmake/FindZStd.cmake) (not find_package,
# so CMAKE_DISABLE_FIND_PACKAGE_ZSTD doesn't help), and builds lib/plugin/
# zstd.so dynamically linked against the host's libzstd. We don't ship a
# bundled zstd, so the resulting plugin would have an unresolved DT_NEEDED
# at runtime. Stub the find module to leave ZSTD_FOUND=FALSE; the compress
# plugin's `IF(${ZSTD_FOUND})` then short-circuits and zstd.so isn't built.
echo 'SET(ZSTD_FOUND FALSE)' > libmariadb/cmake/FindZStd.cmake

# MariaDB's build-time scripts (mysql_install_db.sh.in etc.) bake the
# CMake-time install paths into the generated files. STANDALONE layout
# keeps them relative to $INSTALL_PREFIX, so the resulting tree is
# relocatable without any post-build sed pass.
#
# CMAKE_INSTALL_RPATH expands to $ORIGIN-prefixed entries via -z origin;
# finalize-linux.sh re-asserts the canonical $ORIGIN/../lib value anyway,
# so this primarily helps build-time test binaries find the bundled libs.
#
# On Darwin, CMake handles @loader_path natively when CMAKE_INSTALL_RPATH
# starts with @loader_path. finalize-darwin.sh substitutes the final
# values at tarball time.
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  rpath_origin='@loader_path/../lib'
else
  rpath_origin='$ORIGIN/../lib'
fi

mkdir -p build
cd build

# Pre-stage libfmt: cmake/libfmt.cmake's ExternalProject_Add downloads from
# github at make time, which the Nix sandbox blocks. CMake's download step
# checks <DOWNLOAD_DIR>/<filename> against URL_HASH and skips the network
# fetch if a matching file is already there. Copy the Nix-fetched zip
# (PBS_SRC_LIBFMT, identical contents to upstream's pinned 11.0.2 release)
# into the location cmake's libfmt ExternalProject_Add expects:
# <build>/extra/libfmt/src/fmt-11.0.2.zip. The URL_MD5 check in libfmt.cmake
# verifies the same bytes, so no patching of the cmake module is needed.
mkdir -p extra/libfmt/src
cp "$PBS_SRC_LIBFMT" extra/libfmt/src/fmt-11.0.2.zip

cmake -G "Unix Makefiles" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
  -DCMAKE_INSTALL_RPATH="$rpath_origin" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DINSTALL_LAYOUT=STANDALONE \
  -DINSTALL_LIBDIR=lib \
  -DINSTALL_PLUGINDIR=lib/plugin \
  -DINSTALL_INCLUDEDIR=include/mariadb \
  -DINSTALL_MYSQLSHAREDIR=share/mariadb \
  -DINSTALL_DOCDIR=share/doc/mariadb \
  -DINSTALL_DOCREADMEDIR=share/doc/mariadb \
  -DINSTALL_MANDIR=share/man \
  -DINSTALL_SUPPORTFILESDIR=share/mariadb/support-files \
  -DINSTALL_SCRIPTDIR=bin \
  -DINSTALL_MYSQLTESTDIR= \
  -DINSTALL_SQLBENCHDIR= \
  -DDEFAULT_CHARSET=utf8mb4 \
  -DDEFAULT_COLLATION=utf8mb4_unicode_ci \
  -DWITH_SSL="$PBS_DEP_OPENSSL" \
  -DWITH_ZLIB=system \
  -DZLIB_ROOT="$PBS_DEP_ZLIB" \
  -DCURSES_NCURSES_LIBRARY="$PBS_DEP_NCURSES/lib/libncursesw.${PBS_LIB_EXT}" \
  -DCURSES_INCLUDE_PATH="$PBS_DEP_NCURSES/include" \
  -DLIBEDIT_INCLUDE_DIR="$PBS_DEP_LIBEDIT/include/editline" \
  -DLIBEDIT_LIBRARY="$PBS_DEP_LIBEDIT/lib/libedit.${PBS_LIB_EXT}" \
  -DWITH_PCRE=system \
  -DWITH_JEMALLOC=no \
  -DWITH_NUMA=OFF \
  -DWITH_SYSTEMD=no \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_EMBEDDED_SERVER=OFF \
  -DWITH_WSREP=OFF \
  -DPLUGIN_ROCKSDB=NO \
  -DPLUGIN_MROONGA=NO \
  -DPLUGIN_SPIDER=NO \
  -DPLUGIN_CONNECT=NO \
  -DPLUGIN_COLUMNSTORE=NO \
  -DPLUGIN_S3=NO \
  -DPLUGIN_OQGRAPH=NO \
  -DPLUGIN_CRACKLIB_PASSWORD_CHECK=NO \
  -DPLUGIN_PROVIDER_BZIP2=NO \
  -DPLUGIN_PROVIDER_LZ4=NO \
  -DPLUGIN_PROVIDER_LZMA=NO \
  -DPLUGIN_PROVIDER_LZO=NO \
  -DPLUGIN_PROVIDER_SNAPPY=NO \
  -DCMAKE_DISABLE_FIND_PACKAGE_LIBAIO=ON \
  ..

make -j"$NIX_BUILD_CORES"
make install

# Strip the bits we don't ship:
#   - mysql-test/: full test harness, ~50MB, no runtime purpose.
#   - sql-bench/: legacy benchmark scripts, never invoked in production.
#   - share/doc/: human-readable docs, ship via the source tarball if needed.
#   - lib/cmake/: cmake config files only useful for downstream builds.
#   - share/mariadb/policy/: SELinux policy templates we don't apply.
rm -rf "$PBS_DEPS/mysql-test"
rm -rf "$PBS_DEPS/sql-bench"
rm -rf "$PBS_DEPS/share/doc"
rm -rf "$PBS_DEPS/lib/cmake"
rm -rf "$PBS_DEPS/share/mariadb/policy"

# Drop the mysql_* / mysqld_* deprecated aliases. MariaDB ships them
# (binaries, libraries, man pages, sysv init scripts) as compat shims
# for code from the MySQL era. They're slated for removal upstream and
# we don't want bougie users building habits around names that are going
# away. Every bin/mysql* has a bin/mariadb[d]-* equivalent that stays;
# libmysqlclient.so is an alias of libmariadb.so.3.
rm -f "$PBS_DEPS"/bin/mysql*
rm -f "$PBS_DEPS"/lib/libmysql*
rm -f "$PBS_DEPS"/share/man/man1/mysql*
rm -f "$PBS_DEPS"/share/mariadb/support-files/mysql*.server

mariadbd="$PBS_DEPS/bin/mariadbd"
[ -x "$mariadbd" ] || { echo "FATAL: $mariadbd not produced" >&2; exit 1; }
libmariadb="$(echo "$PBS_DEPS"/lib/libmariadb.*"${PBS_LIB_EXT}"* | awk '{print $1}')"
[ -e "$libmariadb" ] || { echo "FATAL: libmariadb not produced (looked under $PBS_DEPS/lib)" >&2; exit 1; }
pbs_audit_lib "$libmariadb" libmariadb
echo "mariadb OK"
