#!/usr/bin/env bash
# Sign the publish index with cosign keyless OIDC.
#
# Usage: sign-publish-index.sh <index-tree-dir>
#
# Inputs:
#   $1  directory containing index.json (bundle written to index.json.sig alongside it)
#
# Produces <index-tree-dir>/index.json.sig as a Sigstore bundle (signature +
# signing cert + Rekor inclusion proof). Run AFTER URL substitution so the
# signed bytes are final.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <index-tree-dir>" >&2
  exit 1
fi

INDEX_TREE="$1"

cosign sign-blob --yes \
  --bundle "$INDEX_TREE/index.json.sig" \
  "$INDEX_TREE/index.json"
