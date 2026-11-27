#!/usr/bin/env bash
# lzf PECL extension, 1.x line. lzf has no GitHub releases, so this reads
# PECL's REST API: stable.txt is the newest stable version, and that
# release's XML carries the canonical download URL. The URL is taken from
# there rather than built by hand because PECL serves the upper-case
# LZF-<ver>.tgz and the lower-case spelling 404s.
. "$(dirname "$0")/../../../scripts/update-lib.sh"

ver=$(curl -fsSL https://pecl.php.net/rest/r/lzf/stable.txt) \
  || pbs_die "PECL REST lookup failed for lzf"
[[ "$ver" =~ ^1\.[0-9]+\.[0-9]+$ ]] \
  || pbs_die "lzf stable version '$ver' is not on the 1.x line"
base=$(curl -fsSL "https://pecl.php.net/rest/r/lzf/$ver.xml" \
  | sed -n 's|.*<g>\([^<]*\)</g>.*|\1|p') \
  || pbs_die "PECL REST release lookup failed for lzf $ver"
[ -n "$base" ] || pbs_die "no download URL in PECL's lzf $ver release XML"
url="$base.tgz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
