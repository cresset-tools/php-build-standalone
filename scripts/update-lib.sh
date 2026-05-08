# Shared helpers sourced by per-package update scripts.
# Source as:  . "$(dirname "$0")/../../scripts/update-lib.sh"
#
# Functions:
#   pbs_emit_update VERSION URL SHA256
#       Print the JSON the orchestrator expects on stdout, then exit 0.
#   pbs_emit_noop
#       Print "{}" on stdout (orchestrator treats as no-op), then exit 0.
#   pbs_prefetch_sha256 URL
#       Echo the sha256 of the URL's content (hex). Uses nix-prefetch-url
#       so the hash is computed the same way fetchurl does.
#   pbs_latest_github_release OWNER/REPO [TAG_REGEX]
#       Echo the latest non-prerelease tag name from GitHub. TAG_REGEX
#       (extended POSIX) filters which tag names are considered; defaults
#       to "^v?[0-9].*" to skip pre-releases / odd tags.
#   pbs_strip_v VERSION
#       Strip a leading "v" (so "v1.2.3" -> "1.2.3").
#   pbs_die MSG
#       Print to stderr and exit 1.
#
# All helpers are stdout-clean except pbs_emit_*: write progress/log
# output to stderr only. The orchestrator parses stdout strictly.

set -euo pipefail

pbs_die() {
  echo "FATAL: $*" >&2
  exit 1
}

pbs_log() {
  echo "[$PBS_PNAME] $*" >&2
}

pbs_emit_update() {
  local v="$1" u="$2" s="$3"
  printf '{"version":"%s","url":"%s","sha256":"%s"}\n' "$v" "$u" "$s"
}

pbs_emit_noop() {
  printf '{}\n'
}

pbs_strip_v() {
  echo "${1#v}"
}

# Compute sha256 of a URL using nix-prefetch-url. Caches in /tmp keyed
# by URL hash so re-runs of the same URL within a session are cheap.
pbs_prefetch_sha256() {
  local url="$1"
  local cache="/tmp/pbs-update-prefetch.$(echo -n "$url" | sha256sum | cut -c1-16)"
  if [ -s "$cache" ]; then
    cat "$cache"
    return 0
  fi
  local hash
  hash=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null) \
    || pbs_die "nix-prefetch-url failed for $url"
  # nix-prefetch-url emits SRI-base32 by default; convert to hex (which
  # is what sources.nix uses everywhere).
  local hex
  hex=$(nix-hash --type sha256 --to-base16 "$hash" 2>/dev/null) \
    || pbs_die "nix-hash conversion failed for $hash"
  printf '%s' "$hex" > "$cache"
  printf '%s' "$hex"
}

# Latest GitHub release tag. Uses /releases (not /tags) so draft/
# prerelease entries are filtered upstream. TAG_REGEX further filters.
# Requires GITHUB_TOKEN env var to be unset or a valid PAT (rate-limit
# bypass; unauthenticated works for occasional runs).
pbs_latest_github_release() {
  local repo="$1"
  local tag_regex="${2:-^v?[0-9].*}"
  local auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  # Iterate the first page of /releases (non-prerelease, sorted newest
  # first by GitHub) and return the first tag matching tag_regex.
  local tag
  tag=$(
    curl -fsSL "${auth[@]}" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/releases?per_page=30" \
    | jq -r '.[] | select(.draft==false and .prerelease==false) | .tag_name'
  ) || pbs_die "GitHub API failed for $repo"
  echo "$tag" | grep -E "$tag_regex" | head -n1 \
    || pbs_die "no GitHub release tag of $repo matches /$tag_regex/"
}

# Latest git tag from a remote, by `sort -V`. Useful for projects with
# no GitHub release listing (gitlab-only, custom forges) or where you
# want tags-not-releases.
pbs_latest_git_tag() {
  local url="$1"
  local tag_regex="${2:-^v?[0-9].*}"
  git ls-remote --tags --refs "$url" 2>/dev/null \
    | awk -F'/' '{print $NF}' \
    | grep -E "$tag_regex" \
    | sort -V \
    | tail -n1 \
    || pbs_die "no git tag of $url matches /$tag_regex/"
}

# Latest filename from a plain Apache/nginx directory index. Usage:
#   pbs_latest_dir_index URL FILENAME_REGEX
# Returns the matching filename (not the full URL). The regex must
# include version-capturing parens so `sort -V` orders correctly; we
# `sort -V` on the full filename for simplicity.
pbs_latest_dir_index() {
  local url="$1"
  local fname_regex="$2"
  curl -fsSL "$url" \
    | grep -oE "href=\"[^\"]*\"" \
    | sed -E 's/^href="([^"]+)"$/\1/' \
    | grep -E "$fname_regex" \
    | sort -V -u \
    | tail -n1 \
    || pbs_die "no entry in $url matches /$fname_regex/"
}
