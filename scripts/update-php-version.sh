#!/usr/bin/env bash
# Shared body for the per-minor scripts under shared/update/phpVersions/.
# Each minor script (8.1.sh, …, 8.5.sh) sources this; the minor is read
# from PBS_PNAME (which is the leaf attr name, e.g. "8.5").
#
# php.net publishes JSON metadata for every active release branch at
# https://www.php.net/releases/index.php?json&version=<MINOR>.
#
# Branch promotion (e.g. when 8.6 ships) is a deliberate human action:
# add the new branch to sources.nix.phpVersions, drop this script, and
# bump latestPhp. We don't auto-discover new branches.
. "$(dirname "${BASH_SOURCE[0]}")/update-lib.sh"

minor="$PBS_PNAME"
data=$(curl -fsSL "https://www.php.net/releases/index.php?json&version=$minor") \
  || pbs_die "could not fetch php.net release metadata for $minor"

ver=$(echo "$data" | jq -r '.version // empty')
[ -n "$ver" ] || pbs_die "php.net returned no version for branch $minor (EOL?)"

url="https://www.php.net/distributions/php-$ver.tar.xz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
