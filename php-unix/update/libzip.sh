#!/usr/bin/env bash
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release nih-at/libzip)
ver=$(pbs_strip_v "$tag")
url="https://github.com/nih-at/libzip/releases/download/v$ver/libzip-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
