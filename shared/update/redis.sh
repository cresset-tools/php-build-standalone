#!/usr/bin/env bash
# Redis ships tags like "8.6.3". The /releases endpoint already filters
# draft/prerelease tags; the regex pin keeps us on the 8.x stable line
# and accepts only fully-qualified semver (rejects "-rc1" / "-m01"
# milestone tags that occasionally land on /releases).
#
# Bumping to a different major line (when 9.x is promoted) is a
# deliberate human action: change the regex below, run the update,
# then introduce a per-major version map if/when we want to ship
# multiple Redis majors in parallel. Today sources.redis is a single
# flat entry.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release redis/redis '^8\.[0-9]+\.[0-9]+$')
ver="$tag"
url="https://github.com/redis/redis/archive/refs/tags/$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
