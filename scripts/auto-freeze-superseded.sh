#!/usr/bin/env bash
# Capture frozen entries for versions about to be superseded by a
# pending sources.nix bump. Run after scripts/update.py rewrites
# shared/sources.nix, before the bump is committed — every forward
# PHP-minor / service / extension-series version change becomes a
# freeze of the prior version on the live index, so the resulting PR
# already satisfies lint-frozen-coverage.
#
# Usage:
#   auto-freeze-superseded.sh [--against <git-ref>]
#
# Options:
#   --against <ref>  Baseline to diff against. Default origin/main, then main.
#
# Detection mirrors scripts/lint-frozen-coverage.sh (intentional — the lint
# defines the invariant; this script is the matching producer):
#   - PHP minor present in both baseline and current with a forward patch bump
#     → freeze prior php-<v> only. The per-minor xdebug tag
#     (xdebug-*+php<minor>-*) is NOT frozen: it doesn't encode the PHP patch,
#     so the live build rebuilds it under the identical tag and a frozen copy
#     would collide.
#   - PHP minor present in baseline but removed in current (EOL'd)
#     → freeze the last prior php-<v> AND its xdebug: the whole minor leaves
#     the live matrix, so nothing reproduces those tags.
#   - sources.<svc>.version forward bump (mariadb, redis, mkcert)
#     → freeze prior <svc>-<v>.
#   - <ext>Versions.<series>.version forward bump (xdebug, redis-as-ext,
#     imagick, …) → freeze prior <ext>-<v>+php*-* across every PHP minor
#     the series was built against.
#   - <tool>Versions.<series>.version forward bump for a TOOL_VERSION_MAPS
#     member (mysql) → freeze prior <tool>-<v>-*, the flat service shape:
#     these publish tool tags, not PHP-bound extension tags.
#
# Index source is `freeze-publish-entries.sh`, which reads
# $PUBLISH_INDEX_BASE (default https://index.bougie.tools). The update
# workflow sets PUBLISH_INDEX_BASE to match build.yml's INDEX_HOST var.
#
# Idempotent: re-freezing an already-frozen tag is a no-op inside
# freeze-publish-entries.sh.

set -euo pipefail

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
  echo "auto-freeze: cannot find origin/main or main; nothing to diff against." >&2
  exit 0
fi
if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  echo "auto-freeze: ref '$base_ref' not found; skipping." >&2
  exit 0
fi

# Stage current + baseline sources.nix to tempfiles so we can `nix eval`
# both as plain files (same approach as lint-frozen-coverage.sh).
curr_file="$(mktemp --suffix=.nix)"
prev_file="$(mktemp --suffix=.nix)"
trap 'rm -f "$curr_file" "$prev_file"' EXIT

cp shared/sources.nix "$curr_file"
if git show "$base_ref:shared/sources.nix" > "$prev_file" 2>/dev/null; then
  :
elif git show "$base_ref:php-unix/sources.nix" > "$prev_file" 2>/dev/null; then
  :
else
  echo "auto-freeze: neither shared/sources.nix nor php-unix/sources.nix exists in $base_ref; skipping." >&2
  exit 0
fi

curr_php="$(nix eval --json --impure --expr \
  "(import $curr_file).phpVersions" \
  | jq '. | with_entries(.value |= .version)')"

prev_php="$(nix eval --json --impure --expr \
  "(import $prev_file).phpVersions" \
  | jq '. | with_entries(.value |= .version)')"

version_gt() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Freeze runner: defer to the flake app so we get the same toolchain
# (curl/jq/etc.) as a manual freeze, and so PUBLISH_INDEX_BASE / proxy
# env settings propagate identically.
run_freeze() {
  echo "auto-freeze: nix run .#freeze-publish-entries -- $*" >&2
  nix run .#freeze-publish-entries -- "$@"
}

freeze_php_minor() {
  local minor="$1"          # 8.1
  local prior_version="$2"  # 8.1.31
  local reason_version="$3" # version we are advancing to (or prior, for EOL)
  local freeze_xdebug="$4"  # 1 → also freeze xdebug-*+php<minor>-* (EOL only)
  local minor_nodot="${minor//./}"

  # Interpreter tags are patch-keyed (php-8.5.6-…), so a patch bump
  # genuinely supersedes the prior tag → always freeze it.
  #
  # Extension tags are *minor*-keyed (xdebug-3.5.1+php85-…) — they do NOT
  # encode the PHP patch. A patch bump (8.5.6→8.5.7) rebuilds xdebug under
  # the identical tag, so the live build reproduces it and freezing it
  # would collide ("tag appears in both a live build and frozen file").
  # Only an EOL — where the whole minor leaves the live matrix and nothing
  # reproduces the tag — warrants freezing the per-minor xdebug.
  local globs=("php-${prior_version}-*")
  if [[ "$freeze_xdebug" == "1" ]]; then
    globs+=("xdebug-*+php${minor_nodot}-*")
  fi

  run_freeze \
    "${globs[@]}" \
    --reason "superseded by ${reason_version}"
}

# ---- PHP: forward patch bumps -----------------------------------------------
while IFS= read -r minor; do
  curr_version="$(echo "$curr_php" | jq -r --arg m "$minor" '.[$m]')"
  prev_version="$(echo "$prev_php" | jq -r --arg m "$minor" '.[$m] // empty')"

  [[ -z "$prev_version" ]] && continue  # new minor: nothing to freeze yet
  [[ "$curr_version" == "$prev_version" ]] && continue
  version_gt "$curr_version" "$prev_version" || continue

  freeze_php_minor "$minor" "$prev_version" "$curr_version" 0
done < <(echo "$curr_php" | jq -r 'keys[]')

# ---- PHP: EOL'd minors ------------------------------------------------------
while IFS= read -r minor; do
  curr_version="$(echo "$curr_php" | jq -r --arg m "$minor" '.[$m] // empty')"
  [[ -n "$curr_version" ]] && continue  # still active
  prev_version="$(echo "$prev_php" | jq -r --arg m "$minor" '.[$m]')"

  # reason_version = prev_version: there's no "newer" to point at; the
  # frozen-entry reason just records the last shipped patch as the
  # cause of being frozen.
  freeze_php_minor "$minor" "$prev_version" "$prev_version (EOL)" 1
done < <(echo "$prev_php" | jq -r 'keys[]')

# ---- Service pins (mariadb, redis, mkcert) ---------------------------------
freeze_service_bump() {
  local svc="$1"
  local curr_version prev_version
  curr_version="$(nix eval --json --impure --expr \
    "(import $curr_file).${svc}.version or null" 2>/dev/null \
    | jq -r '. // empty')"
  prev_version="$(nix eval --json --impure --expr \
    "(import $prev_file).${svc}.version or null" 2>/dev/null \
    | jq -r '. // empty')"

  [[ -z "$prev_version" || -z "$curr_version" ]] && return 0
  [[ "$curr_version" == "$prev_version" ]] && return 0
  version_gt "$curr_version" "$prev_version" || return 0

  run_freeze \
    "${svc}-${prev_version}-*" \
    --reason "superseded by ${curr_version}"
}

freeze_service_bump mariadb
freeze_service_bump redis
freeze_service_bump mkcert

# ---- Tool version maps ------------------------------------------------------
# Mirrors lint-frozen-coverage.sh's TOOL_VERSION_MAPS (keep the two in sync).
# mysql fans sources.mysqlVersions out into independently-versioned tool
# bundles under one sections/tool/mysql section (flake.nix `mysqlVariants`),
# so its tags are `mysql-<ver>-<target>-default` and freeze-publish-entries.sh
# files them into frozen/mysql.json by kind=tool. The `<ext>Versions` loop
# below would glob `mysql-<ver>+php*-*` and match nothing.
TOOL_VERSION_MAPS=(mysql)

is_tool_version_map() {
  local name="$1"
  local t
  for t in "${TOOL_VERSION_MAPS[@]}"; do
    [[ "$name" == "$t" ]] && return 0
  done
  return 1
}

# ---- Extension version maps (xdebug, redis-as-ext, imagick, …) -------------
# Tags shaped <ext>-<ver>+php<minor>-... — file glob covers every PHP
# minor the series was built against; freeze-publish-entries.sh files
# each into the matching frozen/php-<minor>.json. xdebug forward bumps
# are also covered by the PHP-minor loop above (xdebug-*+php<m>-*), so
# this path is the one that catches an extension-only bump. The
# top-level `redis` service pin (handled above) is distinct from the
# `redisVersions` map handled here — server bundle vs phpredis PECL ext.
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

    [[ -z "$prev_version" ]] && continue
    [[ "$curr_version" == "$prev_version" ]] && continue
    version_gt "$curr_version" "$prev_version" || continue

    if is_tool_version_map "$ext_name"; then
      glob="${ext_name}-${prev_version}-*"
    else
      glob="${ext_name}-${prev_version}+php*-*"
    fi

    run_freeze \
      "$glob" \
      --reason "superseded by ${curr_version}"
  done < <(echo "$curr_series" | jq -r 'keys[]')
done < <(echo "$ext_attrs" | jq -r '.[]')

echo "auto-freeze: done."
