# libpq — PostgreSQL client library, for PHP's pgsql + pdo_pgsql extensions.
#
# Built from the full PostgreSQL source tarball but only the client subtree
# is compiled and installed (see build-libpq.sh): src/common, src/port,
# src/interfaces/libpq, src/bin/pg_config, src/include. Server code, contrib
# modules, psql/pg_dump etc. are skipped — keeps build time and the bundled
# tarball small. Wired against our bundled OpenSSL so libpq supports TLS
# connections (sslmode=require et al).
#
# Source key in sources.nix is "libpq" even though the upstream tarball is
# postgresql-<ver>.tar.bz2 — mkDep's defaults match the dep short-name and
# we treat libpq as the unit we're shipping, not all of PostgreSQL.
{ mkDep, openssl }:
mkDep {
  name = "libpq";
  deps = [ openssl ];
}
