#!/usr/bin/env bash
# Merge Linux and Darwin release-bundle trees into a unified distribution tree.
#
# Usage: merge-publish-tree.sh <linux-bundle-dir> <darwin-bundle-dir> <output-dir>
#
# Inputs:
#   $1  directory containing the Linux release-bundle (index.json, targets/, blobs/)
#   $2  directory containing the Darwin release-bundle (same layout)
#   $3  output directory (created if absent)
#
# Outputs:
#   <output-dir>/merged/       unified tree (targets/ + blobs/ + merged index.json)
#   <output-dir>/index_tree/   like merged/ but without blobs/ (ready for signing)

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 <linux-bundle-dir> <darwin-bundle-dir> <output-dir>" >&2
  exit 1
fi

LINUX_DIR="$1"
DARWIN_DIR="$2"
OUTPUT_DIR="$3"

mkdir -p "$OUTPUT_DIR/merged/blobs"

# Both legs must share the same publish version — the workflow sets
# PUBLISH_VERSION at the env level so both matrix legs see the same
# value, which means versions/<V>/ paths are mergeable. Mismatch is a
# pipeline bug, not an artifact-set difference.
linux_version="$(jq -r '.version' "$LINUX_DIR/index.json")"
darwin_version="$(jq -r '.version' "$DARWIN_DIR/index.json")"
if [ "$linux_version" != "$darwin_version" ]; then
  echo "FATAL: leg version mismatch — Linux=$linux_version Darwin=$darwin_version" >&2
  echo "       Both legs must build with the same PUBLISH_VERSION env." >&2
  exit 1
fi

# Copy Linux tree first (authoritative base). Brings index.json,
# targets/<linux-target>/manifests/, versions/<V>/targets/<linux-target>/,
# and blobs/ along.
cp -r "$LINUX_DIR/." "$OUTPUT_DIR/merged/"

# Merge Darwin targets/ (shared manifest tree) — triples are disjoint,
# no overwrites expected.
if [ -d "$DARWIN_DIR/targets" ]; then
  cp -rn "$DARWIN_DIR/targets/." "$OUTPUT_DIR/merged/targets/"
fi

# Merge Darwin versions/<V>/ — same V across legs (asserted above), so
# the only thing under versions/<V>/ that differs is which target dirs
# each leg populated. cp -rn is the merge: matching subpaths from
# Darwin land alongside Linux's, no overwrites.
if [ -d "$DARWIN_DIR/versions" ]; then
  mkdir -p "$OUTPUT_DIR/merged/versions"
  cp -rn "$DARWIN_DIR/versions/." "$OUTPUT_DIR/merged/versions/"
fi

# Merge Darwin blobs/ — content-addressed, collisions are the same bytes.
if [ -d "$DARWIN_DIR/blobs" ]; then
  # shellcheck disable=SC2015
  cp -rn "$DARWIN_DIR/blobs/." "$OUTPUT_DIR/merged/blobs/" 2>/dev/null || true
fi

# Deep-merge the two index.json roots: .targets maps are disjoint by triple.
# .version is identical (asserted) so $linux.version carries through.
# `generated` is rewritten to wall-clock-now: each per-leg index.json holds
# the reproducible per-leg default (1704067200) from index.nix; the merge
# step is the natural place to stamp the actual publish time on the unified
# index. Allow GENERATED_AT to override for tests/manual runs.
generated_at="${GENERATED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
jq -s --arg generated "$generated_at" '
  .[0] as $linux | .[1] as $darwin |
  $linux
    | .targets = ($linux.targets + $darwin.targets)
    | .generated = $generated
' "$LINUX_DIR/index.json" "$DARWIN_DIR/index.json" > "$OUTPUT_DIR/merged/index.json"

echo "Merged tree:"
echo "  targets: $(jq '.targets | keys | length' "$OUTPUT_DIR/merged/index.json")"
echo "  blobs:   $(find "$OUTPUT_DIR/merged/blobs" -type f 2>/dev/null | wc -l)"

# Split: index_tree/ gets everything except blobs/ (ready for URL substitution + signing)
rsync -a --exclude='blobs/' "$OUTPUT_DIR/merged/" "$OUTPUT_DIR/index_tree/"
echo "Index tree files: $(find "$OUTPUT_DIR/index_tree" -type f | wc -l)"
