#!/usr/bin/env bash
. "$(dirname "$0")/../../scripts/update-lib.sh"

# rabbitmq-c publishes no release assets; the tag archive is the tarball.
tag=$(pbs_latest_github_release alanxz/rabbitmq-c)
ver=$(pbs_strip_v "$tag")
url="https://github.com/alanxz/rabbitmq-c/archive/refs/tags/v$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
