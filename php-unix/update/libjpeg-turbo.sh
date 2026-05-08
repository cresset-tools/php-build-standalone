#!/usr/bin/env bash
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release libjpeg-turbo/libjpeg-turbo)
ver=$(pbs_strip_v "$tag")
url="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$ver/libjpeg-turbo-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
