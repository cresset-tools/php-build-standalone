#!/usr/bin/env bash
# ncurses GNU release tarballs live at ftp.gnu.org/gnu/ncurses/.
. "$(dirname "$0")/../../scripts/update-lib.sh"

fname=$(pbs_latest_dir_index https://ftp.gnu.org/gnu/ncurses/ '^ncurses-[0-9]+\.[0-9]+\.tar\.gz$')
ver=$(echo "$fname" | sed -E 's/^ncurses-(.*)\.tar\.gz$/\1/')
url="https://ftp.gnu.org/gnu/ncurses/$fname"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
