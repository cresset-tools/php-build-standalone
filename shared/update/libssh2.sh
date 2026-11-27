#!/usr/bin/env bash
# libssh2 tags releases on GitHub as libssh2-<ver> and attaches the
# release tarball to each one.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release libssh2/libssh2 '^libssh2-[0-9]+\.[0-9]+\.[0-9]+$')
ver="${tag#libssh2-}"
url="https://github.com/libssh2/libssh2/releases/download/libssh2-$ver/libssh2-$ver.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
