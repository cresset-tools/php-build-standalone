#!/usr/bin/env bash
# OpenSSL ships tags like "openssl-3.5.6". We pin to the 3.5.x LTS line
# (PBS does the same — see comment in sources.nix). The regex enforces
# the 3.5 series so we don't auto-jump to 3.6 / 4.x.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release openssl/openssl '^openssl-3\.5\.[0-9]+$')
ver="${tag#openssl-}"
url="https://github.com/openssl/openssl/releases/download/$tag/openssl-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
