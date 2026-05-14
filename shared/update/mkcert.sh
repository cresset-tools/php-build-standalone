#!/usr/bin/env bash
# mkcert ships tags like "v1.4.4". No LTS line — just take the latest
# stable. The /releases endpoint already filters prereleases.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release FiloSottile/mkcert '^v[0-9]+\.[0-9]+\.[0-9]+$')
ver="${tag#v}"
url="https://github.com/FiloSottile/mkcert/archive/refs/tags/$tag.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
