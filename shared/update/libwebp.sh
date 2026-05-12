#!/usr/bin/env bash
# libwebp uses a Google-hosted tarball but tags on the chromium/webm git.
# The chromium gitiles mirror is awkward to scrape; the `master` mirror
# at https://chromium.googlesource.com/webm/libwebp serves git refs over
# the smart HTTP protocol, so `git ls-remote --tags` works.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_git_tag https://chromium.googlesource.com/webm/libwebp '^v?[0-9]+\.[0-9]+\.[0-9]+$')
ver=$(pbs_strip_v "$tag")
url="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
