#!/usr/bin/env bash
# curl publishes JSON metadata at https://curl.se/info containing the
# current version. The download URL is curl.se/download/curl-X.Y.Z.tar.gz.
. "$(dirname "$0")/../../scripts/update-lib.sh"

ver=$(curl -fsSL https://curl.se/info | awk -F: '/^Version:/ {gsub(/ /,""); print $2}') \
  || pbs_die "could not fetch curl version metadata"
[ -n "$ver" ] || pbs_die "could not parse curl version"
url="https://curl.se/download/curl-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
