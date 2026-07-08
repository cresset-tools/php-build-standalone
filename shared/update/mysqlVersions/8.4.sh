#!/usr/bin/env bash
# MySQL 8.4 LTS updater. Discovers the latest 8.4.x release tag from the
# upstream git repo (Oracle publishes GitHub tags like `mysql-8.4.10`),
# then constructs the source-tarball URL on Oracle's CDN.
#
# Since MySQL 8.3 the source tarball bundles Boost, so 8.4 uses the plain
# `mysql-<ver>.tar.gz` (not the `mysql-boost-` variant 8.0 needs).
#
# URL host: a superseded release lives under cdn.mysql.com/archives/, but
# the *newest* release sits under /Downloads/ until a later patch bumps it
# into the archive. We probe archives first (stable) and fall back to
# Downloads so the updater keeps working the day a new 8.4 patch drops.
. "$(dirname "$0")/../../../scripts/update-lib.sh"

tag=$(pbs_latest_git_tag https://github.com/mysql/mysql-server.git '^mysql-8\.4\.[0-9]+$')
ver="${tag#mysql-}"

archives_url="https://cdn.mysql.com/archives/mysql-8.4/mysql-${ver}.tar.gz"
downloads_url="https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-${ver}.tar.gz"

url=""
for candidate in "$archives_url" "$downloads_url"; do
  if curl -fsI --max-time 30 "$candidate" >/dev/null 2>&1; then
    url="$candidate"
    break
  fi
done
[ -n "$url" ] || pbs_die "neither archives nor Downloads host has mysql-${ver}.tar.gz"

sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
