#!/usr/bin/env bash
# snappy extension, 0.x line. Tags on github.com/kjdev/php-ext-snappy are bare
# versions (0.8.0), and every release attaches the PECL-style source
# tarball snappy-<ver>.tgz, which is what sources.nix pins.
#
# The whole 0.x line is tracked rather than one minor: upstream bumps the
# minor for routine releases (usually a vendored-library update or a new
# PHP minor), so pinning to one would mean no updates at all. The weekly
# PR still has to build the full matrix before it can land.
. "$(dirname "$0")/../../../scripts/update-lib.sh"

tag=$(pbs_latest_github_release kjdev/php-ext-snappy '^0\.[0-9]+\.[0-9]+$')
ver="$tag"
url="https://github.com/kjdev/php-ext-snappy/releases/download/$ver/snappy-$ver.tgz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
