#!/usr/bin/env bash
# PostgreSQL publishes a per-major directory tree under
# https://ftp.postgresql.org/pub/source/, with `v<MAJOR>.<MINOR>/`
# entries inside. We only build libpq, but we still vendor the full
# upstream tarball — pin to the PG 17 line and let the orchestrator
# pick up new minor releases automatically.
#
# We deliberately do NOT auto-bump across major versions (17 → 18):
# new majors occasionally rename / repurpose libpq client-side knobs
# (sslmode flags, channel binding, etc.) and need a human to vet that
# the build-libpq.sh subset still produces a working .so. When PG 18 is
# ready to adopt, bump the regex below in a normal PR.
. "$(dirname "$0")/../../scripts/update-lib.sh"

href=$(pbs_latest_dir_index "https://ftp.postgresql.org/pub/source/" '^v17\.[0-9]+/$') \
  || pbs_die "could not discover latest postgres 17.x"
ver="${href#v}"
ver="${ver%/}"
url="https://ftp.postgresql.org/pub/source/v$ver/postgresql-$ver.tar.bz2"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
