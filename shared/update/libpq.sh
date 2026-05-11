#!/usr/bin/env bash
# PostgreSQL publishes a per-release directory tree under
# https://ftp.postgresql.org/pub/source/, with `v<MAJOR>.<MINOR>/`
# entries inside. We only build libpq, but we still vendor the full
# upstream tarball — track the latest stable release across all majors.
#
# libpq's public client API (libpq-fe.h) is highly stable across PG
# majors: connection strings, PQexec/PQprepare, async/COPY/large-objects
# all date back to pre-9.x and don't break across version bumps. New
# majors add capabilities (channel binding, scram-sha-256, etc.) but
# don't remove or repurpose existing ones. The libpq-only subset of
# build-libpq.sh hasn't needed any version-conditional logic so far,
# so we let the orchestrator follow upstream majors automatically.
. "$(dirname "$0")/../../scripts/update-lib.sh"

href=$(pbs_latest_dir_index "https://ftp.postgresql.org/pub/source/" '^v[0-9]+\.[0-9]+/$') \
  || pbs_die "could not discover latest postgres release"
ver="${href#v}"
ver="${ver%/}"
url="https://ftp.postgresql.org/pub/source/v$ver/postgresql-$ver.tar.bz2"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
