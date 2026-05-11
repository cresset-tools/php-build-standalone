#!/usr/bin/env bash
# libpng has GitHub mirror at glennrp/libpng with v1.6.x tags, but the
# upstream sourceforge URL is what sources.nix uses. We get the version
# from GH (more reliable than scraping sourceforge directory listings)
# and construct the sourceforge URL from it.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_git_tag https://github.com/pnggroup/libpng.git '^v1\.6\.[0-9]+$')
ver=$(pbs_strip_v "$tag")
url="https://download.sourceforge.net/libpng/libpng-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
