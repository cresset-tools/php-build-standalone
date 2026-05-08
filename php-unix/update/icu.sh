#!/usr/bin/env bash
# ICU release tags are "release-<major>-<minor>"  (e.g. release-75-1) and
# the tarball is "icu4c-<major>_<minor>-src.tgz". sources.nix stores the
# version in dotted form (75.1).
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release unicode-org/icu '^release-[0-9]+-[0-9]+$')
# tag = release-75-1 → MAJ=75 MIN=1
rest="${tag#release-}"
maj="${rest%-*}"
min="${rest#*-}"
ver="$maj.$min"
url="https://github.com/unicode-org/icu/releases/download/$tag/icu4c-${maj}_${min}-src.tgz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
