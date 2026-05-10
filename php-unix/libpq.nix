# libpq — PostgreSQL client library, for PHP's pgsql + pdo_pgsql extensions.
#
# Built from the full PostgreSQL source tarball but only the client subtree
# is compiled and installed (see build-libpq.sh): src/common, src/port,
# src/interfaces/libpq, src/bin/pg_config, src/include. Server code, contrib
# modules, psql/pg_dump etc. are skipped — keeps build time and the bundled
# tarball small. Wired against our bundled OpenSSL so libpq supports TLS
# connections (sslmode=require et al).
#
# zlib is listed as a dep purely for build-time conftest loadability: PBS's
# libssl.so.3 / libcrypto.so.3 carry DT_NEEDED libz.so.1 (because OpenSSL
# itself is built with zlib), so PostgreSQL configure's AC_RUN_IFELSE
# conftests — which link -lssl -lcrypto under --with-openssl — refuse to
# start without zlib reachable via LD_LIBRARY_PATH. Listing zlib here puts
# it in PBS_DEPS_LDPATH, which build-libpq.sh exports for the configure
# step. We still pass --without-zlib, so the shipped libpq.so itself does
# not link zlib. Same shape build-libcurl.sh already relies on.
#
# Source key in sources.nix is "libpq" even though the upstream tarball is
# postgresql-<ver>.tar.bz2 — mkDep's defaults match the dep short-name and
# we treat libpq as the unit we're shipping, not all of PostgreSQL.
{ mkDep, openssl, zlib }:
mkDep {
  name = "libpq";
  deps = [ openssl zlib ];
}
