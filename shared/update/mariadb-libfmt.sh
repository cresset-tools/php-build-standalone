#!/usr/bin/env bash
# libfmt, tracked on MariaDB's behalf. MariaDB's cmake/libfmt.cmake
# downloads this archive at build time; the Nix sandbox forbids that, so
# tools/mariadb/build-mariadb.sh pre-stages it under the version-keyed
# filename cmake looks for. A pin that disagrees with the MariaDB tarball
# means cmake ignores the staged file and tries the network, so this has to
# move in lockstep — see the sources.mariadb-libfmt comment.
#
# Why this resolves the MariaDB tag itself instead of reading the pinned
# one: every update script is handed the *pre-update* sources.nix, and
# scripts run in parallel, so sources.mariadb still says the old version
# while shared/update/mariadb.sh is emitting the new one. Reading it would
# leave this pin one cycle behind every MariaDB bump — precisely the drift
# the script exists to prevent. Resolving the same tag from the same regex
# makes the two agree by construction.
#
# NOTE: the release regex below must stay in sync with
# shared/update/mariadb.sh. If the LTS line moves, change both.
. "$(dirname "$0")/../../scripts/update-lib.sh"

mariadb_tag=$(pbs_latest_github_release MariaDB/server '^mariadb-11\.4\.[0-9]+$')
pbs_log "reading libfmt pin from $mariadb_tag"

cmake_url="https://raw.githubusercontent.com/MariaDB/server/${mariadb_tag}/cmake/libfmt.cmake"
cmake_src=$(curl -fsSL "$cmake_url") \
  || pbs_die "cannot fetch cmake/libfmt.cmake for $mariadb_tag ($cmake_url)"

# libfmt.cmake pins two archives: a legacy release for GCC < 4.9 and the
# current one for every other compiler. PBS builds with clang, so we want
# the latter. Take the highest version rather than matching on the cmake
# if/else, which is the part most likely to be reformatted upstream.
ver=$(printf '%s\n' "$cmake_src" \
  | sed -nE 's|.*/fmt/releases/download/([0-9]+\.[0-9]+\.[0-9]+)/.*|\1|p' \
  | sort -V -u | tail -n1)
[ -n "$ver" ] || pbs_die "no fmt release URL found in $cmake_url"

if [ "$ver" = "${PBS_OLD_VERSION:-}" ]; then
  pbs_emit_noop
  exit 0
fi

pbs_log "libfmt $PBS_OLD_VERSION -> $ver"
url="https://github.com/fmtlib/fmt/releases/download/$ver/fmt-$ver.zip"
sha=$(pbs_prefetch_sha256 "$url")
pbs_emit_update "$ver" "$url" "$sha"
