#!/usr/bin/env bash
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release nghttp2/nghttp2)
ver=$(pbs_strip_v "$tag")
url="https://github.com/nghttp2/nghttp2/releases/download/$tag/nghttp2-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
