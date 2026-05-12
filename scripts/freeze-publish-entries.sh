#!/usr/bin/env bash
# Capture live index artifacts into per-minor frozen/*.json files.
#
# Usage:
#   freeze-publish-entries.sh [--from-local <dir>] [--reason "..."] <glob> [<glob>...]
#
# Positional args: one or more shell-glob patterns matched against artifact
#   tags (e.g. 'php-8.1.31-*', 'xdebug-3.5.1+php81-*', 'php-8.1.*').
#
# Options:
#   --from-local <dir>   read index from a local tree (e.g. output of
#                        `nix build .#index`) instead of the network.
#   --reason "<text>"    human-readable reason string stored in frozen entries.
#
# Reads/writes frozen/ directory relative to cwd.
# Idempotent: re-freezing an already-frozen tag is a no-op.
# Exits non-zero on any inconsistency (diverged entry, bad integrity, etc.).

set -euo pipefail

# ---- Argument parsing ----
GLOBS=()
LOCAL_DIR=""
REASON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-local)
      LOCAL_DIR="$2"
      shift 2
      ;;
    --reason)
      REASON="$2"
      shift 2
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 1
      ;;
    *)
      GLOBS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#GLOBS[@]} -eq 0 ]]; then
  echo "usage: $0 [--from-local <dir>] [--reason '...'] <glob> [<glob>...]" >&2
  exit 1
fi

# ---- Index source ----
INDEX_BASE="${PUBLISH_INDEX_BASE:-https://index.example.com}"

fetch_json() {
  local url_or_path="$1"
  if [[ -n "$LOCAL_DIR" ]]; then
    # url_or_path is already an absolute path under LOCAL_DIR; for relative
    # URLs, the caller constructs the path directly.
    cat "$url_or_path"
  else
    curl -fsSL "$url_or_path"
  fi
}

resolve_manifest_path() {
  # Given an absolute server path (e.g.
  # /versions/<V>/targets/.../manifests/.../tag.json) return the
  # absolute file-path or URL to fetch. The path is always absolute
  # and hostname-free per DISTRIBUTION.md §Manifests-and-blobs.
  local path="$1"
  if [[ -n "$LOCAL_DIR" ]]; then
    echo "$LOCAL_DIR${path}"
  else
    echo "${INDEX_BASE}${path}"
  fi
}

if [[ -n "$LOCAL_DIR" ]]; then
  INDEX_ROOT="$LOCAL_DIR/index.json"
else
  INDEX_ROOT="$INDEX_BASE/index.json"
fi

root_json="$(fetch_json "$INDEX_ROOT")"

# ---- Glob matching helper ----
tag_matches_any() {
  local tag="$1"
  for glob in "${GLOBS[@]}"; do
    # Use bash pattern matching (supports * wildcards)
    # shellcheck disable=SC2053
    if [[ "$tag" == $glob ]]; then
      return 0
    fi
  done
  return 1
}

# ---- Minor extraction ----
minor_from_tag() {
  local tag="$1"
  # Interpreter tag: php-8.1.31-<target>-<flavor>  → minor = 8.1
  if [[ "$tag" =~ ^php-([0-9]+\.[0-9]+)\.[0-9]+ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  # Extension tag: <ext>-<ver>+php<minor_no_dot>-<target>-<flavor>
  # e.g. xdebug-3.5.1+php81-... → php minor = 8.1
  if [[ "$tag" =~ \+php([0-9])([0-9]+)- ]]; then
    echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    return
  fi
  echo "" # unknown
}

# ---- Frozen dir ----
FROZEN_DIR="frozen"
mkdir -p "$FROZEN_DIR"

# ---- Walk index ----
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

declare -A minor_updated  # tracks which frozen files were touched

# Walk every target → every section
while IFS= read -r target; do
  # Enumerate sections for this target
  while IFS= read -r section_key; do
    # section_key like "interpreter/php" or "extension/xdebug"
    if [[ -n "$LOCAL_DIR" ]]; then
      section_path="$LOCAL_DIR/targets/$target/sections/$section_key.json"
    else
      section_path="$INDEX_BASE/targets/$target/sections/$section_key.json"
    fi

    section_json="$(fetch_json "$section_path")"
    kind="$(echo "$section_json" | jq -r '.kind')"
    name="$(echo "$section_json" | jq -r '.name')"

    # Walk artifacts in this section
    artifact_count="$(echo "$section_json" | jq '.artifacts | length')"
    for ((i=0; i<artifact_count; i++)); do
      artifact="$(echo "$section_json" | jq --argjson i "$i" '.artifacts[$i]')"
      tag="$(echo "$artifact" | jq -r '.tag')"

      tag_matches_any "$tag" || continue

      # Determine PHP minor for this tag
      minor="$(minor_from_tag "$tag")"
      if [[ -z "$minor" ]]; then
        echo "WARN: cannot determine PHP minor for tag '$tag', skipping" >&2
        continue
      fi

      frozen_file="$FROZEN_DIR/php-$minor.json"

      # Fetch manifest for this artifact. Section rows now carry an absolute
      # server path under .manifest.path (DISTRIBUTION.md §Section-index).
      manifest_path="$(echo "$artifact" | jq -r '.manifest.path')"
      manifest_abs="$(resolve_manifest_path "$manifest_path")"

      manifest_body="$(fetch_json "$manifest_abs")"
      # Canonicalize manifest body (sorted keys, for stable sha256)
      manifest_canonical="$(echo "$manifest_body" | jq -S '.')"

      # Compute sha256 of the canonical manifest bytes
      manifest_sha256_computed="$(echo "$manifest_canonical" | sha256sum | awk '{print $1}')"
      manifest_sha256_section="$(echo "$artifact" | jq -r '.manifest.sha256')"

      if [[ "$manifest_sha256_computed" != "$manifest_sha256_section" ]]; then
        echo "FAIL: manifest sha256 mismatch for tag '$tag'" >&2
        echo "  section entry says: $manifest_sha256_section" >&2
        echo "  computed (jq -S):   $manifest_sha256_computed" >&2
        exit 1
      fi

      # Build section_entry: the artifact entry MINUS the `frozen` field
      # (the generator adds frozen:true at splice time). The on-disk
      # manifest path is derived from section_entry.manifest.path at
      # splice time, so we no longer record it separately.
      section_entry="$(echo "$artifact" | jq -S 'del(.frozen)')"

      # Build the frozen entry struct
      new_entry="$(jq -n -S \
        --arg tag "$tag" \
        --arg kind "$kind" \
        --arg name "$name" \
        --arg target "$target" \
        --arg frozen_at "$NOW" \
        --argjson reason "$(if [[ -n "$REASON" ]]; then echo "\"$REASON\""; else echo "null"; fi)" \
        --argjson section_entry "$section_entry" \
        --argjson manifest "$manifest_canonical" \
        '{
          tag: $tag,
          kind: $kind,
          name: $name,
          target: $target,
          frozen_at: $frozen_at,
          reason: $reason,
          section_entry: $section_entry,
          manifest: $manifest
        }')"

      # Read or initialize the frozen file
      if [[ -f "$frozen_file" ]]; then
        existing="$(cat "$frozen_file")"
      else
        existing="$(jq -n --arg minor "$minor" '{schema: 1, minor: $minor, entries: []}')"
      fi

      # Check for existing entry with this tag
      existing_entry="$(echo "$existing" | jq --arg t "$tag" --arg tgt "$target" \
        '.entries[] | select(.tag == $t and .target == $tgt)' || true)"

      if [[ -n "$existing_entry" ]]; then
        # Compare section_entry sha256 + manifest sha256
        ex_manifest_sha256="$(echo "$existing_entry" | jq -r '.section_entry.manifest.sha256')"
        ex_manifest_body_sha256="$(echo "$existing_entry" | jq -S '.manifest' | sha256sum | awk '{print $1}')"
        new_manifest_body_sha256="$(echo "$new_entry" | jq -S '.manifest' | sha256sum | awk '{print $1}')"

        if [[ "$ex_manifest_sha256" != "$manifest_sha256_computed" ]] || \
           [[ "$ex_manifest_body_sha256" != "$new_manifest_body_sha256" ]]; then
          echo "FAIL: diverged frozen entry for tag '$tag' (target $target)" >&2
          echo "  existing manifest sha256 in section_entry: $ex_manifest_sha256" >&2
          echo "  newly-fetched manifest sha256:             $manifest_sha256_computed" >&2
          exit 1
        fi

        # Identical — no-op, preserve existing frozen_at
        echo "  (no-op) $tag already frozen (target $target)"
        continue
      fi

      # Merge new entry into the frozen file (preserve existing frozen_at on
      # entries already present; new entries get frozen_at=$NOW)
      updated="$(echo "$existing" | jq -S \
        --argjson e "$new_entry" \
        '.entries = (.entries + [$e]) | .entries |= sort_by(.tag + .target)')"

      echo "$updated" > "$frozen_file"
      minor_updated["$minor"]="1"
      echo "  frozen: $tag (target $target) → $frozen_file"

    done
  done < <(echo "$root_json" | jq -r --arg t "$target" '.targets[$t].sections | keys[]')

done < <(echo "$root_json" | jq -r '.targets | keys[]')

if [[ ${#minor_updated[@]} -eq 0 ]]; then
  echo "No new entries frozen (all matched tags were already present or no tags matched)."
else
  echo "Updated frozen files:"
  for m in "${!minor_updated[@]}"; do
    echo "  $FROZEN_DIR/php-$m.json"
  done
fi
