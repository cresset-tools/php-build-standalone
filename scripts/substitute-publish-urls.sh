#!/usr/bin/env bash
# Substitute {INDEX_BASE} and {BLOB_BASE} placeholders in all *.json files.
#
# Usage: substitute-publish-urls.sh <index-tree-dir> <index-host> <blob-host>
#
# Inputs:
#   $1  directory containing the index tree (modified in-place)
#   $2  index hostname, e.g. "index.example.com"
#   $3  blob hostname, e.g. "blobs.example.com"
#
# Substitutes {INDEX_BASE} → https://<index-host>
#             {BLOB_BASE}  → https://<blob-host>
# Fails if any placeholder remains after substitution.

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 <index-tree-dir> <index-host> <blob-host>" >&2
  exit 1
fi

INDEX_TREE="$1"
INDEX_HOST="$2"
BLOB_HOST="$3"

INDEX_BASE="https://${INDEX_HOST}"
BLOB_BASE="https://${BLOB_HOST}"

find "$INDEX_TREE" -name '*.json' -exec \
  sed -i "s|{INDEX_BASE}|${INDEX_BASE}|g" {} +
find "$INDEX_TREE" -name '*.json' -exec \
  sed -i "s|{BLOB_BASE}|${BLOB_BASE}|g" {} +

echo "URL substitution complete"

# Fail loudly if any placeholder survived
if grep -r '{INDEX_BASE}\|{BLOB_BASE}' "$INDEX_TREE/" 2>/dev/null; then
  echo "FAIL: unsubstituted placeholders remain" >&2
  exit 1
fi
