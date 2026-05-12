#!/usr/bin/env bash
# MariaDB ships tags like "mariadb-11.4.4". Pin to the 11.4 LTS line
# (current LTS, supported through May 2029). Bumping to a different LTS
# line (e.g. when 11.8 is promoted) is a deliberate human action: change
# the regex below, run the update, then bump latestMariaDB if/when we
# introduce a per-LTS version map. Today sources.mariadb is a single
# flat entry, so the bump is one PR.
#
# The /releases endpoint already filters draft/prerelease tags (RCs like
# mariadb-11.4.5-rc surface as prerelease and get dropped); the regex
# pin enforces the LTS line on top of that.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release MariaDB/server '^mariadb-11\.4\.[0-9]+$')
ver="${tag#mariadb-}"
url="https://archive.mariadb.org/mariadb-$ver/source/mariadb-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
