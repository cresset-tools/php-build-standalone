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

# Copy Linux tree first (authoritative base)
cp -r "$LINUX_DIR/." "$OUTPUT_DIR/merged/"

# Merge Darwin targets/ — triples are disjoint, no overwrites expected
if [ -d "$DARWIN_DIR/targets" ]; then
  cp -rn "$DARWIN_DIR/targets/." "$OUTPUT_DIR/merged/targets/"
fi

# Merge Darwin blobs/ — content-addressed, collisions are the same bytes
if [ -d "$DARWIN_DIR/blobs" ]; then
  # shellcheck disable=SC2015
  cp -rn "$DARWIN_DIR/blobs/." "$OUTPUT_DIR/merged/blobs/" 2>/dev/null || true
fi

# Deep-merge the two index.json roots: .targets maps are disjoint by triple
jq -s '
  .[0] as $linux | .[1] as $darwin |
  $linux | .targets = ($linux.targets + $darwin.targets)
' "$LINUX_DIR/index.json" "$DARWIN_DIR/index.json" > "$OUTPUT_DIR/merged/index.json"

echo "Merged tree:"
echo "  targets: $(jq '.targets | keys | length' "$OUTPUT_DIR/merged/index.json")"
echo "  blobs:   $(find "$OUTPUT_DIR/merged/blobs" -type f 2>/dev/null | wc -l)"

# Split: index_tree/ gets everything except blobs/ (ready for URL substitution + signing)
rsync -a --exclude='blobs/' "$OUTPUT_DIR/merged/" "$OUTPUT_DIR/index_tree/"
echo "Index tree files: $(find "$OUTPUT_DIR/index_tree" -type f | wc -l)"
