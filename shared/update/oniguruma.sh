#!/usr/bin/env bash
# Oniguruma's tarball is named onig-<ver>.tar.gz (not oniguruma-).
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release kkos/oniguruma)
ver=$(pbs_strip_v "$tag")
url="https://github.com/kkos/oniguruma/releases/download/$tag/onig-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
