#!/usr/bin/env bash
# Merge per-leg release-bundle trees into a unified distribution tree.
#
# Usage: merge-publish-tree.sh <bundle-dir>... <output-dir>
#
# Inputs:
#   one or more directories, each a per-leg release-bundle (index.json,
#   versions/, blobs/) — e.g. the Linux-glibc, Linux-musl, and Darwin legs.
#   The last argument is the output directory (created if absent).
#
# Each leg populates a disjoint set of target triples; the merge unions
# their versions/ + blobs/ subtrees and deep-merges the index.json
# .targets maps. The first leg is the authoritative base.
#
# Outputs:
#   <output-dir>/merged/       unified tree (versions/ + blobs/ + merged index.json)
#   <output-dir>/index_tree/   like merged/ but without blobs/ (ready for signing)

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <bundle-dir>... <output-dir>" >&2
  exit 1
fi

# Last arg is the output dir; everything before it is an input leg.
OUTPUT_DIR="${!#}"
BUNDLE_DIRS=("${@:1:$#-1}")

mkdir -p "$OUTPUT_DIR/merged/blobs"

# All legs must share the same publish version — the workflow sets
# PUBLISH_VERSION at the env level so every leg sees the same value, which
# means versions/<V>/ paths are mergeable. Mismatch is a pipeline bug, not
# an artifact-set difference.
base_version="$(jq -r '.version' "${BUNDLE_DIRS[0]}/index.json")"
for d in "${BUNDLE_DIRS[@]}"; do
  v="$(jq -r '.version' "$d/index.json")"
  if [ "$v" != "$base_version" ]; then
    echo "FATAL: leg version mismatch — $d=$v vs base=$base_version" >&2
    echo "       All legs must build with the same PUBLISH_VERSION env." >&2
    exit 1
  fi
done

# Copy the first leg as authoritative base (index.json, versions/<V>/, blobs/).
cp -r "${BUNDLE_DIRS[0]}/." "$OUTPUT_DIR/merged/"

# Merge each subsequent leg's versions/<V>/ + blobs/. Same V across legs
# (asserted), so the only differences under versions/<V>/ are which target
# dirs (and manifests) each leg populated; cp -rn unions without overwrites.
# blobs/ are content-addressed, so any collision is the same bytes.
for d in "${BUNDLE_DIRS[@]:1}"; do
  if [ -d "$d/versions" ]; then
    mkdir -p "$OUTPUT_DIR/merged/versions"
    cp -rn "$d/versions/." "$OUTPUT_DIR/merged/versions/"
  fi
  if [ -d "$d/blobs" ]; then
    # shellcheck disable=SC2015
    cp -rn "$d/blobs/." "$OUTPUT_DIR/merged/blobs/" 2>/dev/null || true
  fi
done

# Deep-merge all index.json roots: .targets maps are disjoint by triple.
# .version is identical (asserted) so the base's carries through.
# `generated` is rewritten to wall-clock-now: each per-leg index.json holds
# the reproducible per-leg default (1704067200) from index.nix; the merge
# step is the natural place to stamp the actual publish time on the unified
# index. Allow GENERATED_AT to override for tests/manual runs.
generated_at="${GENERATED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
index_files=()
for d in "${BUNDLE_DIRS[@]}"; do index_files+=("$d/index.json"); done
jq -s --arg generated "$generated_at" '
  . as $all
  | $all[0]
    | .targets = (reduce $all[] as $o ({}; . + $o.targets))
    | .generated = $generated
' "${index_files[@]}" > "$OUTPUT_DIR/merged/index.json"

echo "Merged tree:"
echo "  targets: $(jq '.targets | keys | length' "$OUTPUT_DIR/merged/index.json")"
echo "  blobs:   $(find "$OUTPUT_DIR/merged/blobs" -type f 2>/dev/null | wc -l)"

# Split: index_tree/ gets everything except blobs/ (ready for URL substitution + signing)
rsync -a --exclude='blobs/' "$OUTPUT_DIR/merged/" "$OUTPUT_DIR/index_tree/"
echo "Index tree files: $(find "$OUTPUT_DIR/index_tree" -type f | wc -l)"
