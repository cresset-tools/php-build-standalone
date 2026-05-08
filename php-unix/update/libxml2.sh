#!/usr/bin/env bash
# libxml2 ships at https://download.gnome.org/sources/libxml2/<MAJ.MIN>/.
# We pin to the 2.13.x line (PHP requires >= 2.9.4 but we picked 2.13.x
# in sources.nix; bumping to 2.14 needs a manual review). Tags come from
# the GNOME GitLab mirror.
. "$(dirname "$0")/../../scripts/update-lib.sh"

tag=$(pbs_latest_git_tag https://gitlab.gnome.org/GNOME/libxml2.git '^v?2\.13\.[0-9]+$')
ver=$(pbs_strip_v "$tag")
url="https://download.gnome.org/sources/libxml2/2.13/libxml2-$ver.tar.xz"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
