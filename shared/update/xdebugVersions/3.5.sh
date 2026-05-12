#!/usr/bin/env bash
# Xdebug 3.5.x line. Tags on github.com/xdebug/xdebug look like 3.5.1.
# Tarballs are hosted at xdebug.org/files/xdebug-<ver>.tgz (PECL-style),
# which is what sources.nix uses.
. "$(dirname "$0")/../../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release xdebug/xdebug '^3\.5\.[0-9]+$')
ver="$tag"
url="https://xdebug.org/files/xdebug-$ver.tgz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
