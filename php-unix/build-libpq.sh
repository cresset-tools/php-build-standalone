#!/usr/bin/env bash
# Build libpq (PostgreSQL client library) only — not the server, not psql,
# not pg_dump. PHP's pgsql + pdo_pgsql extensions consume libpq via the
# pg_config binary (--with-pgsql=DIR expects DIR/bin/pg_config).
#
# Strategy: run upstream PostgreSQL configure (it cross-checks too many
# things to skip), then `make` and `make install` only the subdirs that
# produce / install client artifacts. Server build is never invoked, so
# the heavy backend deps (kerberos, perl, python, llvm, etc.) don't need
# to exist in the sandbox.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh); mkDep
# auto-appends -I${dep}/include -L${dep}/lib for openssl and exports
# PBS_DEP_OPENSSL.

set -euo pipefail

: "${PBS_SRC_LIBPQ:?}"
: "${PBS_VER_LIBPQ:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_OPENSSL:?libpq needs openssl for TLS support}"

src_dir="$PBS_SOURCES/postgresql-${PBS_VER_LIBPQ}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBPQ" -C "$PBS_SOURCES"
cd "$src_dir"

# --without-* flags below disable optional features whose probes would
# otherwise scan the host or pull in deps we don't bundle:
#   readline/zlib/icu/zstd/lz4 — server-side or psql-side niceties
#   --with-openssl              — wire libpq to our bundled OpenSSL so
#                                 sslmode=require works on consumer machines
# We do NOT pass --enable-shared / --disable-static; PostgreSQL builds
# both libpq.so and libpq.a by default and PHP's pgsql extension picks
# the .so via the standard SONAME lookup. The .a is dropped post-install.
# Conftest-loadability wiring. PostgreSQL configure does AC_RUN_IFELSE
# ("checking test program") after --with-openssl has appended
# `-lssl -lcrypto` to LIBS, so every conftest binary gets DT_NEEDED
# entries for libssl.so.3 / libcrypto.so.3 (kept by setup-env-linux's
# `-Wl,--no-as-needed`). PBS's libssl/libcrypto in turn carry
# DT_NEEDED libz.so.1, which is why libpq.nix lists zlib as a dep
# even though we pass --without-zlib to configure: that listing is
# what gets zlib's lib dir into PBS_DEPS_LDPATH, so the conftest
# binary can resolve libz.so.1 at run time. setup-env-linux
# deliberately doesn't export LD_LIBRARY_PATH globally (would shadow
# the host libc for build tools), so we scope it to ./configure here
# — same pattern build-libcurl.sh uses.
env "$PBS_RPATH_VAR=${PBS_DEPS_LDPATH:-}" \
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --bindir="$PBS_DEPS/bin" \
  --includedir="$PBS_DEPS/include" \
  --without-readline \
  --without-zlib \
  --without-icu \
  --without-zstd \
  --without-lz4 \
  --with-openssl

# Build only the client subtree. src/common + src/port are static
# convenience archives that libpq links into itself; they're not
# installed but must exist before src/interfaces/libpq's link step.
# src/include must be built first because libpq's compile depends on
# the generated pg_config*.h headers it produces.
make -C src/include -j"$NIX_BUILD_CORES"
make -C src/common -j"$NIX_BUILD_CORES"
make -C src/port -j"$NIX_BUILD_CORES"
make -C src/interfaces/libpq -j"$NIX_BUILD_CORES"
make -C src/bin/pg_config -j"$NIX_BUILD_CORES"

# Install only the client artifacts: headers (include/postgresql/...,
# include/libpq-fe.h, include/postgres_ext.h), libpq.so + symlinks,
# libpq.pc, and the pg_config binary that PHP's configure consumes.
make -C src/include install
make -C src/interfaces/libpq install
make -C src/bin/pg_config install

# Drop the static archive — finalize gates would also flag it as no-op
# weight in the bundled tree, and PHP only ever links the .so.
rm -f "$PBS_DEPS/lib/libpq.a"

# Drop server / internal headers. PHP's pgsql + pdo_pgsql only need the
# public client headers (libpq-fe.h, libpq-events.h, postgres_ext.h,
# libpq/libpq-fs.h, plus pg_config_ext.h / pg_config_os.h /
# pg_config_manual.h transitively). pg_config.h is server config and
# bakes the configure-time CONFIGURE_ARGS string verbatim — including
# the build-sandbox PKG_CONFIG_PATH with raw nixpkgs /nix/store paths
# that are not pbs-prefixed and so survive finalize-common's text
# detoxify, tripping the no-/nix/store gate. The include/postgresql/
# subtree contains server + internal headers and bundles its own copy
# of pg_config.h with the same leak. Both are dead weight for a libpq-
# only consumer; remove them.
rm -f "$PBS_DEPS/include/pg_config.h"
rm -rf "$PBS_DEPS/include/postgresql"

# Sanity: libpq.${PBS_LIB_EXT} exists and passes the audit.
_libpq="$PBS_DEPS/lib/libpq.${PBS_LIB_EXT}"
[ -e "$_libpq" ] || { echo "FATAL: $_libpq not produced" >&2; exit 1; }
pbs_audit_lib "$_libpq" libpq

# pg_config is consumed by PHP's configure; verify it runs and reports
# our prefix back, otherwise --with-pgsql=$PBS_DEP_LIBPQ in build-php.sh
# would silently skip the extension.
_pg_config="$PBS_DEPS/bin/pg_config"
[ -x "$_pg_config" ] || { echo "FATAL: $_pg_config not produced" >&2; exit 1; }
_reported_includedir="$("$_pg_config" --includedir)"
if [ "$_reported_includedir" != "$PBS_DEPS/include" ]; then
  echo "FATAL: pg_config --includedir reports '$_reported_includedir', expected '$PBS_DEPS/include'" >&2
  exit 1
fi

echo "libpq OK"
