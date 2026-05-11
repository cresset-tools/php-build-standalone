#!/usr/bin/env bash
# bzip2 lives at sourceware.org with a flat directory layout. The project
# is dormant (last release 2019), so this is mostly a no-op — but keep
# the script so the global update doesn't have a hole.
. "$(dirname "$0")/../../scripts/update-lib.sh"

fname=$(pbs_latest_dir_index https://sourceware.org/pub/bzip2/ '^bzip2-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$')
ver=$(echo "$fname" | sed -E 's/^bzip2-(.*)\.tar\.gz$/\1/')
url="https://sourceware.org/pub/bzip2/$fname"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
