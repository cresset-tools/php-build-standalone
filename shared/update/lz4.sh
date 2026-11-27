#!/usr/bin/env bash
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release lz4/lz4)
ver=$(pbs_strip_v "$tag")
url="https://github.com/lz4/lz4/releases/download/$tag/lz4-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
