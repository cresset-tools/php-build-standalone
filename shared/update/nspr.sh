#!/usr/bin/env bash
# NSPR is published as plain tarballs under
# https://archive.mozilla.org/pub/nspr/releases/v<version>/src/. The
# index page uses server-absolute hrefs (`/pub/nspr/releases/v4.36/`)
# which the generic pbs_latest_dir_index helper doesn't know how to
# strip, so we parse the version out directly.
#
# Pin to the 4.x series — NSPR has been on v4 for over a decade and a
# major bump would imply an API break NSS would need to track in
# lockstep, which is a deliberate human action.
. "$(dirname "$0")/../../scripts/update-lib.sh"

ver=$(curl -fsSL "https://archive.mozilla.org/pub/nspr/releases/" \
  | grep -oE 'href="/pub/nspr/releases/v4\.[0-9]+(\.[0-9]+)?/"' \
  | sed -E 's|href="/pub/nspr/releases/v(4\.[0-9]+(\.[0-9]+)?)/"|\1|' \
  | sort -V -u \
  | tail -n1) \
  || pbs_die "no NSPR v4.x release found"
url="https://archive.mozilla.org/pub/nspr/releases/v${ver}/src/nspr-${ver}.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
