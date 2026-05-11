#!/usr/bin/env bash
# libiconv GNU release tarballs at ftp.gnu.org/pub/gnu/libiconv/.
# Releases are infrequent (latest 1.17 dates to 2022).
. "$(dirname "$0")/../../scripts/update-lib.sh"

fname=$(pbs_latest_dir_index https://ftp.gnu.org/pub/gnu/libiconv/ '^libiconv-[0-9]+\.[0-9]+\.tar\.gz$')
ver=$(echo "$fname" | sed -E 's/^libiconv-(.*)\.tar\.gz$/\1/')
url="https://ftp.gnu.org/pub/gnu/libiconv/$fname"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
