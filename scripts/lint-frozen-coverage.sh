#!/usr/bin/env bash
# Verify that every interpreter / service version bump in sources.nix has
# a corresponding frozen entry for the superseded version.
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
#   3. For each service-style flat pin (sources.mariadb, sources.redis,
#      sources.mkcert): if .version changed (forward bump), at least one
#      entry in frozen/<svc>.json must start with `<svc>-<prior>-`. These
#      services have a single pinned version (the source attrset is flat,
#      not a versions map), so one frozen file per service accumulates every
#      superseded release rather than the per-minor split used for PHP.
#   4. For each `<ext>Versions.<series>.version` forward bump (excluding
#      phpVersions, which is rule 1, and the tool maps of rule 5): at
#      least one entry across the frozen/php-*.json set must start with
#      `<ext>-<prior>+php`. The tag is filed under whichever PHP minor it
#      was built for, so the lint accepts a match in any minor file.
#   5. For each `<tool>Versions.<series>.version` forward bump where
#      <tool> is a TOOL_VERSION_MAPS member (mysql): same requirement as
#      rule 3 — at least one entry in frozen/<tool>.json starting with
#      `<tool>-<prior>-`. These are tools that happen to ship several
#      concurrently-pinned series, not PHP-bound extensions.

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
# Using `nix eval --expr 'import ./shared/sources.nix'` would resolve
# the path through the flake's tree (staged/HEAD), making unstaged edits
# invisible. Copy the working-tree file to a tempfile and eval that
# absolute path — matches how the baseline is handled and gives the lint
# the same view a developer sees on disk.
curr_file="$(mktemp --suffix=.nix)"
prev_file="$(mktemp --suffix=.nix)"
trap 'rm -f "$curr_file" "$prev_file"' EXIT

cp shared/sources.nix "$curr_file"
# The baseline ref may predate the shared/php restructure (when
# sources.nix lived at php-unix/sources.nix), or this lint may run
# against a branch that simply hasn't introduced sources.nix yet.
# Fall back to the legacy path; if neither exists in base_ref, there's
# nothing to compare against — emit a WARN and exit clean rather than
# hard-failing the CI gate.
if git show "$base_ref:shared/sources.nix" > "$prev_file" 2>/dev/null; then
  :
elif git show "$base_ref:php-unix/sources.nix" > "$prev_file" 2>/dev/null; then
  :
else
  echo "WARN: neither shared/sources.nix nor php-unix/sources.nix exists in $base_ref; skipping lint." >&2
  exit 0
fi

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

# ---- Service-style single-version pins (MariaDB, Redis, …) ----
# Same invariant as PHP, with a flatter shape: sources.<svc> is a single
# {url,sha256,version} attrset rather than a versions map, so there's no
# minor to iterate. One frozen file (frozen/<svc>.json) accumulates every
# superseded release. // empty handles the case where the baseline predates
# the relevant pin (e.g. comparing against an old main branch).
check_service_frozen_coverage() {
  local svc="$1"
  local prior_version="$2"
  local curr_version="$3"
  local context="$4"

  local frozen_file="frozen/$svc.json"
  local prefix="$svc-$prior_version-"

  if [[ ! -f "$frozen_file" ]]; then
    echo "FAIL: $context" >&2
    echo "      $frozen_file does not exist." >&2
    echo "To freeze the prior version:" >&2
    echo "    nix run .#freeze-publish-entries -- '$svc-${prior_version}-*' --reason 'superseded by ${curr_version}'" >&2
    echo "    git add $frozen_file && git commit" >&2
    FAIL=1
    return
  fi

  local count
  count="$(jq --arg p "$prefix" '[.entries[] | select(.tag | startswith($p))] | length' "$frozen_file")"
  if [[ "$count" -eq 0 ]]; then
    echo "FAIL: $context" >&2
    echo "      No entries starting with '$prefix' found in $frozen_file." >&2
    echo "To freeze the prior version:" >&2
    echo "    nix run .#freeze-publish-entries -- '$svc-${prior_version}-*' --reason 'superseded by ${curr_version}'" >&2
    echo "    git add $frozen_file && git commit" >&2
    FAIL=1
  fi
}

check_service_pin() {
  local svc="$1"
  local label="$2"

  local curr_v prev_v
  curr_v="$(nix eval --json --impure --expr \
    "(import $curr_file).$svc.version or null" 2>/dev/null \
    | jq -r '. // empty')"
  prev_v="$(nix eval --json --impure --expr \
    "(import $prev_file).$svc.version or null" 2>/dev/null \
    | jq -r '. // empty')"

  if [[ -n "$prev_v" && -n "$curr_v" \
     && "$curr_v" != "$prev_v" \
     && $(version_gt "$curr_v" "$prev_v" && echo yes || echo no) == "yes" ]]; then
    local context="$label: $prev_v → $curr_v version bump in sources.nix, but $prev_v is not frozen."
    check_service_frozen_coverage "$svc" "$prev_v" "$curr_v" "$context"
  fi
}

check_service_pin mariadb MariaDB
check_service_pin redis   Redis
check_service_pin mkcert  mkcert

# ---- Tool version maps ------------------------------------------------------
# A `<name>Versions` attr is *not* automatically a PHP-bound extension. mysql
# is fanned out over sources.mysqlVersions into independently-versioned tool
# bundles (flake.nix `mysqlVariants`) that coexist under one sections/tool/
# mysql section, so its tags are `mysql-<ver>-<target>-default` — the flat
# service shape of rule 3 — not `mysql-<ver>+php<minor>-...`. The freeze script
# files those under frozen/mysql.json (it routes kind=tool by name), so the
# coverage check is check_service_frozen_coverage, not the extension one.
# Listed explicitly because the two map shapes are structurally identical in
# sources.nix; only the consuming derivation tells them apart.
TOOL_VERSION_MAPS=(mysql)

is_tool_version_map() {
  local name="$1"
  local t
  for t in "${TOOL_VERSION_MAPS[@]}"; do
    [[ "$name" == "$t" ]] && return 0
  done
  return 1
}

# ---- Extension version maps (xdebugVersions, redisVersions, …) ----
# Each is a series→{version,url,sha256} map producing tags shaped
#   <ext>-<ver>+php<minor_no_dot>-<target>-<flavor>
# which the freeze script files into frozen/php-<minor>.json. The lint
# accepts a match in any minor file: an extension series may have built
# for multiple PHP minors, and the freeze splits the entries across
# those files. // empty handles new series introduced in the bump.
# TOOL_VERSION_MAPS members are routed to the service check instead —
# they share this map shape but publish tool tags.

check_extension_frozen_coverage() {
  local ext="$1"            # xdebug, redis, imagick, …
  local series="$2"         # 3.5, 6.3, …
  local prior_version="$3"
  local curr_version="$4"

  local prefix="${ext}-${prior_version}+php"
  local context="${ext} ${series}: $prior_version → $curr_version version bump in sources.nix, but $prior_version is not frozen."

  shopt -s nullglob
  local files=(frozen/php-*.json)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "FAIL: $context" >&2
    echo "      No frozen/php-*.json files exist." >&2
    echo "To freeze the prior version:" >&2
    echo "    nix run .#freeze-publish-entries -- '${ext}-${prior_version}+php*-*' --reason 'superseded by ${curr_version}'" >&2
    FAIL=1
    return
  fi

  local count
  count="$(jq --arg p "$prefix" -s '[.[].entries[] | select(.tag | startswith($p))] | length' "${files[@]}")"
  if [[ "$count" -eq 0 ]]; then
    echo "FAIL: $context" >&2
    echo "      No entries starting with '$prefix' found in any frozen/php-*.json." >&2
    echo "To freeze the prior version:" >&2
    echo "    nix run .#freeze-publish-entries -- '${ext}-${prior_version}+php*-*' --reason 'superseded by ${curr_version}'" >&2
    FAIL=1
  fi
}

# Discover *Versions attrs (excluding phpVersions, handled above).
ext_attrs="$(nix eval --json --impure --expr \
  "builtins.filter (n: builtins.match \".*Versions\" n != null && n != \"phpVersions\") (builtins.attrNames (import $curr_file))")"

while IFS= read -r ext_attr; do
  [[ -z "$ext_attr" ]] && continue
  ext_name="${ext_attr%Versions}"

  curr_series="$(nix eval --json --impure --expr \
    "(import $curr_file).${ext_attr} or {}" \
    | jq '. | with_entries(.value |= .version)')"
  prev_series="$(nix eval --json --impure --expr \
    "(import $prev_file).${ext_attr} or {}" \
    | jq '. | with_entries(.value |= .version)')"

  while IFS= read -r series; do
    curr_version="$(echo "$curr_series" | jq -r --arg s "$series" '.[$s]')"
    prev_version="$(echo "$prev_series" | jq -r --arg s "$series" '.[$s] // empty')"

    [[ -z "$prev_version" ]] && continue                # new series
    [[ "$curr_version" == "$prev_version" ]] && continue
    version_gt "$curr_version" "$prev_version" || continue

    if is_tool_version_map "$ext_name"; then
      context="$ext_name $series: $prev_version → $curr_version version bump in sources.nix, but $prev_version is not frozen."
      check_service_frozen_coverage "$ext_name" "$prev_version" "$curr_version" "$context"
    else
      check_extension_frozen_coverage "$ext_name" "$series" "$prev_version" "$curr_version"
    fi
  done < <(echo "$curr_series" | jq -r 'keys[]')
done < <(echo "$ext_attrs" | jq -r '.[]')

if [[ $FAIL -eq 0 ]]; then
  echo "OK: frozen coverage lint passed."
fi

exit "$FAIL"
