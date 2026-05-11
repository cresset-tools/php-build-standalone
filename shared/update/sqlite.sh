#!/usr/bin/env bash
# SQLite version encoding: 3.47.2 → 3470200 (M*1000000 + N*10000 + P*100).
# The download URL embeds both the year of release and the packed version:
#   https://www.sqlite.org/<YEAR>/sqlite-autoconf-<PACKED>.tar.gz
# sqlite.org publishes a CSV-like manifest at the bottom of download.html
# starting with `PRODUCT,<version>,<year>/<filename>,...`. We parse that.
. "$(dirname "$0")/../../scripts/update-lib.sh"

manifest=$(curl -fsSL https://www.sqlite.org/download.html) \
  || pbs_die "could not fetch sqlite download.html"

# Extract autoconf row (the "amalgamation as autoconf tarball" entry).
row=$(echo "$manifest" \
  | grep -oE 'PRODUCT,[^,]+,[^,]+sqlite-autoconf[^,]+\.tar\.gz' \
  | head -n1) \
  || pbs_die "could not find sqlite-autoconf row in download.html"

ver=$(echo "$row" | awk -F, '{print $2}')
relpath=$(echo "$row" | awk -F, '{print $3}')   # e.g. 2024/sqlite-autoconf-3470200.tar.gz
url="https://www.sqlite.org/$relpath"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
