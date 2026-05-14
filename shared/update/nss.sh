#!/usr/bin/env bash
# NSS is published as plain tarballs under
# https://archive.mozilla.org/pub/security/nss/releases/NSS_<major>_<minor>_RTM/src/.
# The release-index page uses server-absolute hrefs which the generic
# pbs_latest_dir_index helper doesn't know how to strip, so we parse
# the version out directly.
#
# Pin to the 3.x line — NSS has been on v3 for years; bumps are
# Firefox-coupled. We follow only RTM tags (release-to-manufacturing);
# beta/RC tags don't carry the `_RTM` suffix.
#
# Some releases also carry a hotfix segment (NSS_3_101_1_RTM). The
# regex below captures both the simple and hyphen-suffixed forms; the
# version mapping turns `NSS_3_101_1_RTM` into `3.101.1`, matching
# Mozilla's `nss-3.101.1.tar.gz` filename convention.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(curl -fsSL "https://archive.mozilla.org/pub/security/nss/releases/" \
  | grep -oE 'href="/pub/security/nss/releases/NSS_3_[0-9]+(_[0-9]+)?_RTM/"' \
  | sed -E 's|href="/pub/security/nss/releases/(NSS_3_[0-9]+(_[0-9]+)?_RTM)/"|\1|' \
  | sort -V -u \
  | tail -n1) \
  || pbs_die "no NSS_3_*_RTM release found"

# Convert NSS_3_123_RTM → 3.123  (or NSS_3_101_1_RTM → 3.101.1)
rest="${tag#NSS_}"
rest="${rest%_RTM}"
ver="${rest//_/.}"

url="https://archive.mozilla.org/pub/security/nss/releases/${tag}/src/nss-${ver}.tar.gz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
