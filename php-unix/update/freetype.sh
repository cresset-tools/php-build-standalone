#!/usr/bin/env bash
# FreeType tarballs live at savannah; tags live at gitlab.freedesktop.org
# (mirror) under names like VER-2-13-3. Conversion: VER-2-13-3 → 2.13.3.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_git_tag https://gitlab.freedesktop.org/freetype/freetype.git '^VER-[0-9]+(-[0-9]+)+$')
# VER-2-13-3 → 2-13-3 → 2.13.3
ver=$(echo "${tag#VER-}" | tr - .)
url="https://download.savannah.gnu.org/releases/freetype/freetype-$ver.tar.xz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
