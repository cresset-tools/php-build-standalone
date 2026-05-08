#!/usr/bin/env bash
# libedit releases live at thrysoee.dk/editline/. Filenames are
# libedit-YYYYMMDD-MAJ.MIN.tar.gz; we pick the highest by `sort -V`,
# which orders date prefixes correctly.
. "$(dirname "$0")/../../scripts/update-lib.sh"

fname=$(pbs_latest_dir_index https://thrysoee.dk/editline/ '^libedit-[0-9]{8}-[0-9]+\.[0-9]+\.tar\.gz$')
ver=$(echo "$fname" | sed -E 's/^libedit-(.*)\.tar\.gz$/\1/')
url="https://thrysoee.dk/editline/$fname"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
