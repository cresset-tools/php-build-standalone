#!/usr/bin/env bash
# Build Oracle MySQL Community Server (mysqld + client tools + libmysqlclient)
# into ${PBS_DEPS}.
#
# CMake invocation uses INSTALL_LAYOUT=STANDALONE so the install tree is
# self-contained: bin/, lib/, lib/plugin/, share/. mysqld resolves its
# basedir from argv[0] at runtime, so the whole tree stays portable as long
# as bin/ and share/ remain siblings.
#
# RPATH is set to $ORIGIN/../lib (Linux) / @loader_path/../lib (Darwin) so the
# bundled OpenSSL / zlib / ncurses resolve via the install-tree's own lib/
# rather than the system path. finalize-{linux,darwin}.sh runs after install
# and re-asserts RPATHs across the merged tree.
#
# Getting host codegen tools to run mid-build is fiddly here (unlike
# tools/mariadb). MySQL builds comp_err / comp_sql etc. and runs them to
# generate headers; those tools link our shared zlib/openssl and so need
# working RPATHs from the *build tree*. Two knobs together make that work:
#   * CMAKE_BUILD_WITH_INSTALL_RPATH=OFF — don't stamp the unresolved
#     $ORIGIN/../lib install RPATH onto build-tree binaries (ON did, and
#     comp_err died with "libz.so.1: cannot open shared object file").
#   * CMAKE_BUILD_RPATH=<dep>/lib list — mkDep hands our deps to the compiler
#     as -L flags in LDFLAGS, and cmake does NOT fold raw -L dirs into the
#     build RPATH (only full-path / imported-target libs), so OFF alone still
#     left comp_err without a libz RPATH. This names the dirs explicitly.
# The tempting shortcut — LD_LIBRARY_PATH around `make` (build-php.sh does
# this) — backfires: MySQL's Makefiles re-invoke the nixpkgs cmake at
# cmake_check_build_system, and our engine-less OpenSSL on the loader path
# then fails to satisfy that cmake's libcurl (undefined symbol ENGINE_init).
# The build RPATHs stay in the build tree; `make install` relinks the shipped
# binaries to $ORIGIN/../lib, and finalize re-asserts the store-path RPATHs.
#
# Dependency policy: MySQL vendors nearly its whole stack under the source
# tree (boost/, extra/{icu,zstd,lz4,protobuf,libevent,curl,...}) and
# static-links it. We keep it that way — the only external C libraries we
# link dynamically are the four PBS deps that carry closure/shared-state or
# build-correctness value: openssl (pinned to the interpreter closure), zlib
# (openssl's DT_NEEDED libz), ncurses (terminal capability), and libedit (the
# interactive client's line editing). MySQL's *bundled* libedit
# (extra/libedit) fails to build under clang 18 — its terminal.c calls
# termcap functions (tgoto/tgetent/tputs) that the C99 implicit-declaration
# error rejects — so we use WITH_EDITLINE=system against PBS's known-good
# libedit (the same one MariaDB links), which also gives closure dedup. Optional auth plugins that would drag in
# system libraries we don't ship (FIDO->libudev, LDAP/SASL/Kerberos) are
# disabled or left to no-op when their system libs are absent. Curl is
# skipped outright (WITH_CURL=none): MySQL's vendored curl only builds with
# the ancient openssl11-on-el7 combo, not our OpenSSL 3.5, and its only
# consumers are optional telemetry / OCI-auth plugins irrelevant to dev.
# libresolv: see the RESOLV_LIBRARY pin above — libmysqlclient's DNS-SRV code
# needs the glibc-2.17 sysroot's libresolv, not the nixpkgs stub cmake's
# find picks by default. libresolv.so.2 is on finalize-linux.sh's system
# allowlist, so the resulting DT_NEEDED passes the audit.
#
# Sun RPC likewise comes from the vendored extra/tirpc (WITH_TIRPC=bundled):
# MySQL's rpc.cmake only probes the host /usr/include for rpc/rpc.h, which
# the clang-toolchain sandbox doesn't populate, so the bundled tirpc is the
# reliable source regardless of the build host.
#
# Server-feature scope: Group Replication (WITHOUT_GROUP_REPLICATION=1) and
# MySQL Router (WITH_ROUTER=OFF) are dropped. They're multi-node clustering /
# routing features with no role in a local single-instance dev server — the
# same stance tools/mariadb takes with WITH_WSREP=OFF. Dropping Group
# Replication also removes its libmysqlgcs XCOM layer, the sole consumer of
# a build-time rpcgen, so we don't have to ship an rpcgen codegen tool.

set -euo pipefail

: "${PBS_SRC_MYSQL:?}"
: "${PBS_VER_MYSQL:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?}"
: "${PBS_DEP_OPENSSL:?}"
: "${PBS_DEP_NCURSES:?}"
: "${PBS_DEP_LIBEDIT:?}"

src_dir="$PBS_SOURCES/mysql-${PBS_VER_MYSQL}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_MYSQL" -C "$PBS_SOURCES"
cd "$src_dir"

# Neutralize MySQL's private-OpenSSL bundling (MYSQL_CHECK_SSL_DLLS).
#
# When WITH_SSL points at a custom OpenSSL, the stock macro copies
# libssl/libcrypto into lib/private/ (patching binaries' RPATH to
# $ORIGIN/../lib/private) AND installs the openssl CLI as bin/my_openssl.
# Both fight our model: we link the *pinned* PBS OpenSSL through the
# content-addressed store/ and let finalize re-assert the $ORIGIN store-path
# RPATHs (the same path tools/mariadb and the PHP build take). The private
# copy would duplicate the pinned libssl, and the CLI copy aborts install
# outright — `FIND_PROGRAM(OPENSSL_EXECUTABLE openssl)` comes back NOTFOUND
# because build-openssl.sh prunes bin/openssl from the dep, so cmake_install
# tries to install a literal `my_OPENSSL_EXECUTABLE-NOTFOUND`.
#
# We can't make it a bare no-op, though: on 8.4 the macro is called from
# FIND_CUSTOM_OPENSSL, and the OpenSSL::SSL / OpenSSL::Crypto *imported
# targets* take their Unix IMPORTED_LOCATION from ${COPIED_OPENSSL_LIBRARY} /
# ${COPIED_CRYPTO_LIBRARY} — variables that only the copy step sets. Leaving
# them empty makes the imported targets locationless, and cmake emits them
# into build.make as the literal prerequisite `OpenSSL::SSL-NOTFOUND`; the
# `::` makes GNU Make read a bogus static-pattern rule and die with "target
# pattern contains no '%'". (8.1-8.3 point IMPORTED_LOCATION straight at
# ${OPENSSL_SSL_LIBRARY} instead, so a bare no-op happens to work there.)
#
# So redefine the macro to *skip the copy but still publish the store-path
# .so we already found* (OPENSSL_LIBRARY / CRYPTO_LIBRARY, resolved by the
# FIND_LIBRARY calls just above the call site) as the COPIED_* locations.
# The imported targets then resolve to the pinned store openssl directly, no
# lib/private copy, no my_openssl. Appended after the original definition so
# last-definition-wins makes this body run at every call site. It's a MACRO
# (caller scope), so the SETs land in FIND_CUSTOM_OPENSSL's scope where the
# ADD_LIBRARY(OpenSSL::SSL ...) reads them.
ssl_cmake="$src_dir/cmake/ssl.cmake"
[ -f "$ssl_cmake" ] || { echo "FATAL: $ssl_cmake missing; MySQL layout changed" >&2; exit 1; }
grep -q 'MACRO(MYSQL_CHECK_SSL_DLLS)' "$ssl_cmake" \
  || { echo "FATAL: MYSQL_CHECK_SSL_DLLS not found; neutralization stale" >&2; exit 1; }
cat >> "$ssl_cmake" <<'PBS_SSL_DLLS_NOOP'

# --- PBS: skip private-OpenSSL copy, point imported targets at the store
#     .so directly (see build-mysql.sh for the full rationale) ---
MACRO(MYSQL_CHECK_SSL_DLLS)
  SET(COPIED_OPENSSL_LIBRARY "${OPENSSL_LIBRARY}")
  SET(COPIED_CRYPTO_LIBRARY "${CRYPTO_LIBRARY}")
ENDMACRO()
PBS_SSL_DLLS_NOOP

# Force the bundled Protobuf AND Abseil to build STATIC on every target.
#
# Under our clang toolchain (no symbol interposition), a mixed static/shared
# Protobuf+Abseil makes `protoc` heap-corrupt at codegen ("free(): invalid
# pointer") on Abseil's duplicated global singletons — the same crash whether
# it's shared-protobuf+static-abseil or the reverse. Both-static is the config
# MySQL 8.0-8.3 already ship on Linux, and it's what works.
#
# Protobuf: extra/protobuf/CMakeLists.txt only picks static when it sees
# `-static-libgcc` in CMAKE_CXX_FLAGS (`IF(CMAKE_CXX_FLAGS MATCHES
# "-static-libgcc")`). We can't drive it with that flag: Apple clang rejects
# `-static-libgcc` as an unsupported option and fails the very first compiler
# check on Darwin, and a `-Dprotobuf_BUILD_SHARED_LIBS=OFF` override doesn't
# help either — 8.0's else-branch forces it back ON with `CACHE INTERNAL`,
# ignoring the command line (8.4 respects -D, but 8.0 does not). So flip the
# probe to `IF(TRUE)` in-source: Protobuf then always builds static, on every
# platform, reaching the exact SET(protobuf_BUILD_SHARED_LIBS OFF) branch the
# `-static-libgcc` path used. (Our toolchain already static-links libstdc++/
# libgcc via a positional libstdc++.a, so no compiler flag is needed anyway.)
#
# Abseil: since 8.4, extra/abseil/CMakeLists.txt has an `IF(LINUX)
# SET(absl_BUILD_SHARED_LIBS ON)` that forces Abseil *shared* on Linux
# regardless — the reverse mismatch. Flip it to OFF. 8.1-8.3, and every
# version on Darwin/Apple, default Abseil static already, so it's a no-op there.
#
# Both are apply-if-present with a guard that fails the build loudly if a
# future layout change leaves either library forced shared.
pb_cmake="$src_dir/extra/protobuf/CMakeLists.txt"
[ -f "$pb_cmake" ] || { echo "FATAL: $pb_cmake missing; MySQL layout changed" >&2; exit 1; }
perl -0777 -i -pe 's/IF\(CMAKE_CXX_FLAGS MATCHES "-static-libgcc"\)/IF(TRUE) # PBS: always build Protobuf static (clang, no symbol interposition)/' "$pb_cmake"
grep -q 'IF(TRUE) # PBS' "$pb_cmake" \
  || { echo "FATAL: Protobuf static-probe patch did not apply; static-Protobuf fix is stale" >&2; exit 1; }

absl_cmake="$src_dir/extra/abseil/CMakeLists.txt"
[ -f "$absl_cmake" ] || { echo "FATAL: $absl_cmake missing; MySQL layout changed" >&2; exit 1; }
perl -0777 -i -pe 's/(IF\(LINUX\)\n\s*SET\(absl_BUILD_SHARED_LIBS )ON\)/${1}OFF)/' "$absl_cmake"
if perl -0777 -ne 'exit(/IF\(LINUX\)\n\s*SET\(absl_BUILD_SHARED_LIBS ON\)/ ? 0 : 1)' "$absl_cmake"; then
  echo "FATAL: Abseil still forced shared on Linux after patch; static-Abseil fix is stale" >&2
  exit 1
fi

# Boost is required to build (not to run) MySQL. Since 8.3 the source tarball
# bundles it under extra/boost/ (cmake/boost.cmake finds it automatically);
# the 8.0 `mysql-boost-` tarball instead carries a top-level boost/ that must
# be pointed at explicitly. Auto-detect: only pass -DWITH_BOOST when the
# top-level boost/ exists, otherwise let cmake use its extra/boost default.
boost_args=()
if [ -d "$src_dir/boost" ]; then
  boost_args=(-DWITH_BOOST="$src_dir/boost")
fi

# libmysqlclient's DNS-SRV support (dns_srv.cc) calls __res_nsearch /
# __dn_expand, and the shared lib is linked with --no-undefined, so those
# must resolve at link time. MySQL locates the resolver with
# FIND_LIBRARY(RESOLV_LIBRARY NAMES resolv) — but cmake's find searches the
# nixpkgs *host* paths, not our clang toolchain's sysroot, so it picks up
# nixpkgs' modern-glibc libresolv, which is an empty stub (glibc folded the
# res_* symbols into libc in 2.34). Pin RESOLV_LIBRARY at the CentOS 7
# sysroot's real libresolv.so (glibc 2.17, where the symbols still live); the
# DT_NEEDED stays the bare libresolv.so.2 soname, resolved from the target
# host's own glibc at runtime. Linux-only: Darwin has no PBS_SYSROOT and
# provides the resolver via libSystem.
resolv_args=()
if [ -z "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  : "${PBS_SYSROOT:?}"
  resolv_args=(-DRESOLV_LIBRARY="$PBS_SYSROOT/usr/lib64/libresolv.so")
else
  # Darwin: libmysql/CMakeLists.txt gates HAVE_DNS_SRV on
  # FIND_LIBRARY(RESOLV_LIBRARY NAMES resolv) and FATALs if it fails. Under
  # the nixpkgs SDK toolchain that find comes back empty (libresolv is an SDK
  # .tbd stub, not on cmake's default library search path), so pre-seed the
  # cache var with the bare `resolv` name: the check then passes and the
  # linker gets -lresolv, which resolves against the SDK's libresolv.tbd. The
  # res_*/dn_expand symbols live there and are re-exported by libSystem at
  # runtime, so the resulting LC_LOAD_DYLIB is the system /usr/lib/
  # libresolv.9.dylib — on finalize-darwin's allowlist.
  #
  # The *header* <resolv.h> that dns_srv.cc includes is a separate matter:
  # the framework SDK doesn't ship it, so add darwin.libresolv's -dev include
  # dir (handed in by mysql.nix as PBS_DARWIN_RESOLV_DEV) to the compile path.
  : "${PBS_DARWIN_RESOLV_DEV:?set by mysql.nix on Darwin}"
  export CFLAGS="${CFLAGS:-} -I$PBS_DARWIN_RESOLV_DEV/include"
  export CXXFLAGS="${CXXFLAGS:-} -I$PBS_DARWIN_RESOLV_DEV/include"
  resolv_args=(-DRESOLV_LIBRARY=resolv)
fi

# Darwin: cmake/package_name.cmake's APPLE branch runs `sw_vers` to derive
# DEFAULT_PLATFORM, but sw_vers isn't on PATH in the nix build sandbox, so its
# empty output makes LIST(GET ...) abort configure. That string only names
# MySQL's *own* package artifact — which we never build (tarball.nix produces
# ours) — and the whole block is skipped when SYSTEM_NAME_AND_PROCESSOR is
# already set. Pre-seed it so the sw_vers path is never taken.
pkgname_args=()
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  pkgname_args=(-DSYSTEM_NAME_AND_PROCESSOR=aarch64-apple-darwin)
fi

if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  rpath_origin='@loader_path/../lib'
else
  rpath_origin='$ORIGIN/../lib'
fi

# OpenSSL 3.5's <openssl/*.h> macros instantiate function-pointer casts that
# clang flags under -Wcast-function-type-strict; keep it a warning so any
# TU that includes an OpenSSL header (and MySQL has many) doesn't die if a
# -Werror slips in. MYSQL_MAINTAINER_MODE=OFF already keeps -Werror off for
# a from-tarball build; this is belt-and-suspenders.
export CFLAGS="${CFLAGS:-} -Wno-error=cast-function-type-strict"
export CXXFLAGS="${CXXFLAGS:-} -Wno-error=cast-function-type-strict"

# (Static Protobuf/Abseil is forced by the in-source CMakeLists patches above,
# not a compiler flag — see the pb_cmake / absl_cmake block. We intentionally
# do NOT pass -static-libgcc: Apple clang rejects it, and it isn't needed since
# the toolchain already static-links libstdc++/libgcc via a positional archive.)

mkdir -p build
cd build

cmake -G "Unix Makefiles" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
  -DCMAKE_INSTALL_RPATH="$rpath_origin" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=OFF \
  -DCMAKE_BUILD_RPATH="$PBS_DEP_ZLIB/lib;$PBS_DEP_OPENSSL/lib;$PBS_DEP_NCURSES/lib;$PBS_DEP_LIBEDIT/lib" \
  -DCMAKE_PREFIX_PATH="$PBS_DEP_OPENSSL;$PBS_DEP_ZLIB;$PBS_DEP_NCURSES;$PBS_DEP_LIBEDIT" \
  -DMYSQL_MAINTAINER_MODE=OFF \
  -DINSTALL_LAYOUT=STANDALONE \
  -DINSTALL_BINDIR=bin \
  -DINSTALL_SBINDIR=bin \
  -DINSTALL_LIBDIR=lib \
  -DINSTALL_PLUGINDIR=lib/plugin \
  -DINSTALL_INCLUDEDIR=include/mysql \
  -DINSTALL_MYSQLSHAREDIR=share \
  -DINSTALL_DOCDIR=share/doc/mysql \
  -DINSTALL_DOCREADMEDIR=share/doc/mysql \
  -DINSTALL_MANDIR=share/man \
  -DINSTALL_SUPPORTFILESDIR=share/support-files \
  -DINSTALL_MYSQLTESTDIR= \
  -DDEFAULT_CHARSET=utf8mb4 \
  -DDEFAULT_COLLATION=utf8mb4_0900_ai_ci \
  -DWITH_SSL="$PBS_DEP_OPENSSL" \
  -DWITH_ZLIB=system \
  -DZLIB_ROOT="$PBS_DEP_ZLIB" \
  -DWITH_ZSTD=bundled \
  -DWITH_LZ4=bundled \
  -DWITH_ICU=bundled \
  -DWITH_PROTOBUF=bundled \
  -DWITH_LIBEVENT=bundled \
  -DWITH_TIRPC=bundled \
  -DWITH_EDITLINE=system \
  -DWITH_CURL=none \
  -DWITH_FIDO=none \
  -DCURSES_LIBRARY="$PBS_DEP_NCURSES/lib/libncursesw.${PBS_LIB_EXT}" \
  -DCURSES_INCLUDE_PATH="$PBS_DEP_NCURSES/include" \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_ROUTER=OFF \
  -DWITHOUT_GROUP_REPLICATION=1 \
  -DWITH_SYSTEMD=OFF \
  -DIGNORE_AIO_CHECK=1 \
  -DENABLED_LOCAL_INFILE=ON \
  "${resolv_args[@]}" \
  "${pkgname_args[@]}" \
  "${boost_args[@]}" \
  ..

make -j"$NIX_BUILD_CORES"
make install

# Strip the bits we don't ship:
#   - mysql-test/: full test harness, no runtime purpose (also skipped at
#     configure via INSTALL_MYSQLTESTDIR=, belt-and-suspenders).
#   - share/doc/: human-readable docs, ship via the source tarball if needed.
#   - lib/*.a: static client/mysqlservices archives, only useful downstream.
#   - lib/pkgconfig, lib/cmake: build-integration files with no runtime role.
rm -rf "$PBS_DEPS/mysql-test"
rm -rf "$PBS_DEPS/share/doc"
rm -rf "$PBS_DEPS/lib/cmake"
rm -rf "$PBS_DEPS/lib/pkgconfig"
rm -f  "$PBS_DEPS"/lib/*.a

mysqld="$PBS_DEPS/bin/mysqld"
[ -x "$mysqld" ] || { echo "FATAL: $mysqld not produced" >&2; exit 1; }

# Audit the shared client library's link surface when it's present (MySQL
# builds libmysqlclient.so unless shared client libs are disabled). Falls
# back to auditing mysqld itself so we never skip the relocatability probe.
libmysqlclient="$(echo "$PBS_DEPS"/lib/libmysqlclient."${PBS_LIB_EXT}"* | awk '{print $1}')"
if [ -e "$libmysqlclient" ]; then
  pbs_audit_lib "$libmysqlclient" libmysqlclient
else
  pbs_audit_lib "$mysqld" mysqld
fi
echo "mysql OK"
