#!/usr/bin/env bash
# Verify that every PHP patch-version bump in sources.nix has a corresponding
# frozen entry for the superseded patch.
#
# Usage: lint-frozen-coverage.sh [--against <git-ref>]
#
# Options:
#   --against <ref>   compare against this git ref instead of origin/main.
#
# Checks:
#   1. For each PHP minor present in BOTH current and baseline sources.nix:
#      if the patch version changed, at least one entry in
#      frozen/php-<minor>.json must start with `php-<prior-version>-`.
#   2. For each PHP minor in baseline but absent in current (EOL'd):
#      same coverage requirement for the prior version.

set -euo pipefail

# ---- Argument parsing ----
BASE_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --against)
      BASE_REF="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# ---- Resolve base ref ----
resolve_base_ref() {
  if [[ -n "$BASE_REF" ]]; then
    echo "$BASE_REF"
    return
  fi
  if git rev-parse --verify "origin/main" >/dev/null 2>&1; then
    echo "origin/main"
    return
  fi
  if git rev-parse --verify "main" >/dev/null 2>&1; then
    echo "main"
    return
  fi
  echo ""
}

base_ref="$(resolve_base_ref)"
if [[ -z "$base_ref" ]]; then
  echo "WARN: cannot find origin/main or main; skipping frozen-coverage lint." >&2
  exit 0
fi

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  echo "WARN: ref '$base_ref' not found; skipping frozen-coverage lint." >&2
  exit 0
fi

# ---- Stage current + baseline sources.nix to tempfiles ----
# Using `nix eval --expr 'import ./php-unix/sources.nix'` would resolve
# the path through the flake's tree (staged/HEAD), making unstaged edits
# invisible. Copy the working-tree file to a tempfile and eval that
# absolute path — matches how the baseline is handled and gives the lint
# the same view a developer sees on disk.
curr_file="$(mktemp --suffix=.nix)"
prev_file="$(mktemp --suffix=.nix)"
trap 'rm -f "$curr_file" "$prev_file"' EXIT

cp php-unix/sources.nix "$curr_file"
git show "$base_ref:php-unix/sources.nix" > "$prev_file"

curr_versions="$(nix eval --json --impure --expr \
  "(import $curr_file).phpVersions" \
  | jq '. | with_entries(.value |= .version)')"

prev_versions="$(nix eval --json --impure --expr \
  "(import $prev_file).phpVersions" \
  | jq '. | with_entries(.value |= .version)')"

# ---- Compare versions ----
FAIL=0

check_frozen_coverage() {
  local minor="$1"
  local prior_version="$2"
  local curr_version="$3"
  local context="$4"

  local frozen_file="frozen/php-$minor.json"
  local prefix="php-$prior_version-"

  if [[ ! -f "$frozen_file" ]]; then
    echo "FAIL: $context" >&2
    echo "      $frozen_file does not exist." >&2
    print_fix_hint "$minor" "$prior_version" "$curr_version"
    FAIL=1
    return
  fi

  local count
  count="$(jq --arg p "$prefix" '[.entries[] | select(.tag | startswith($p))] | length' "$frozen_file")"
  if [[ "$count" -eq 0 ]]; then
    echo "FAIL: $context" >&2
    echo "      No entries starting with '$prefix' found in $frozen_file." >&2
    print_fix_hint "$minor" "$prior_version" "$curr_version"
    FAIL=1
  fi
}

print_fix_hint() {
  local minor="$1"
  local prior_version="$2"
  local curr_version="$3"
  local minor_nodot="${minor//./}"
  cat >&2 <<EOF
To freeze the prior patch:
    nix run .#freeze-publish-entries -- 'php-${prior_version}-*' 'xdebug-*+php${minor_nodot}-*' --reason 'superseded by ${curr_version}'
    git add frozen/php-${minor}.json && git commit
EOF
}

# version_gt: returns 0 (true) if $1 is strictly greater than $2 (semver compare)
version_gt() {
  # Sort two version strings; if $1 sorts after $2 it is newer.
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Check minors present in both curr and prev
while IFS= read -r minor; do
  curr_version="$(echo "$curr_versions" | jq -r --arg m "$minor" '.[$m]')"
  prev_version="$(echo "$prev_versions" | jq -r --arg m "$minor" '.[$m] // empty')"

  [[ -z "$prev_version" ]] && continue  # new minor, nothing to lint

  # Only flag a forward patch bump (curr strictly newer than prev).
  # If prev is newer (e.g. the base branch is ahead of this branch)
  # there's nothing to freeze — the bump hasn't happened yet here.
  if [[ "$curr_version" != "$prev_version" ]] && version_gt "$curr_version" "$prev_version"; then
    context="PHP $minor: $prev_version → $curr_version patch bump in sources.nix, but $prev_version is not frozen."
    check_frozen_coverage "$minor" "$prev_version" "$curr_version" "$context"
  fi
done < <(echo "$curr_versions" | jq -r 'keys[]')

# Check minors in prev but absent in curr (EOL'd)
while IFS= read -r minor; do
  curr_version="$(echo "$curr_versions" | jq -r --arg m "$minor" '.[$m] // empty')"
  [[ -n "$curr_version" ]] && continue  # still active

  prev_version="$(echo "$prev_versions" | jq -r --arg m "$minor" '.[$m]')"
  context="PHP $minor EOL'd (removed from sources.nix), but $prev_version is not frozen."
  check_frozen_coverage "$minor" "$prev_version" "$prev_version" "$context"
done < <(echo "$prev_versions" | jq -r 'keys[]')

if [[ $FAIL -eq 0 ]]; then
  echo "OK: frozen coverage lint passed."
fi

exit "$FAIL"
