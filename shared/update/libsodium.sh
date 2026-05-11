#!/usr/bin/env bash
# libsodium tags releases on GitHub as <ver>-RELEASE; the canonical tarball
# is hosted at download.libsodium.org. We use the GitHub release listing
# to pick the latest non-prerelease, then construct the libsodium.org URL.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release jedisct1/libsodium '^[0-9]+\.[0-9]+\.[0-9]+-RELEASE$')
ver="${tag%-RELEASE}"
url="https://download.libsodium.org/libsodium/releases/libsodium-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
