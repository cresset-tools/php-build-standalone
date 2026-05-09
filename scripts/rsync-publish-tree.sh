# Push a prepared publish tree to the two-vhost origin described in
# DISTRIBUTION.md "Hosting". Three rsync passes:
#   1. Index tree minus index.json (sections + manifests land first)
#   2. Blobs (content-addressed; existing files are no-ops)
#   3. Index.json + index.json.sig last — atomic-ish ordering so the root
#      never references a section file that hasn't landed yet.
#
# Args:
#   $1 — index tree dir (must contain index.json[, .sig], targets/, ...)
#   $2 — blobs dir (the blobs/ subtree, content-addressed files)
#   $3 — index hostname (e.g. index.example.com)
#   $4 — blob hostname  (e.g. blobs.example.com)
#
# Env:
#   PUBLISH_SSH_KEY — SSH private key contents. Required.
#   PUBLISH_SSH_USER — remote user (default: deploy)
#   INDEX_REMOTE_PATH — remote path on $3 (default: /srv/index/)
#   BLOB_REMOTE_PATH  — remote path on $4 (default: /srv/blobs/)

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <index-tree-dir> <blobs-dir> <index-host> <blob-host>" >&2
  exit 2
fi

INDEX_TREE="$1"
BLOBS_DIR="$2"
INDEX_HOST="$3"
BLOB_HOST="$4"
USER="${PUBLISH_SSH_USER:-deploy}"
INDEX_REMOTE="${INDEX_REMOTE_PATH:-/srv/index/}"
BLOB_REMOTE="${BLOB_REMOTE_PATH:-/srv/blobs/}"

if [ -z "${PUBLISH_SSH_KEY:-}" ]; then
  echo "FAIL: PUBLISH_SSH_KEY is not set" >&2
  exit 1
fi

# Stage the key in a tempdir we control; never write into ~/.ssh.
KEY_TMP="$(mktemp -d)"
trap 'rm -rf "$KEY_TMP"' EXIT
KEY_FILE="$KEY_TMP/publish_key"
printf '%s\n' "$PUBLISH_SSH_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

SSH_CMD="ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "==> rsync index tree (excluding index.json[.sig]) → ${USER}@${INDEX_HOST}:${INDEX_REMOTE}"
rsync -az --delete \
  -e "$SSH_CMD" \
  --exclude='index.json' --exclude='index.json.sig' \
  "${INDEX_TREE}/" \
  "${USER}@${INDEX_HOST}:${INDEX_REMOTE}"

echo "==> rsync blobs → ${USER}@${BLOB_HOST}:${BLOB_REMOTE}"
rsync -az \
  -e "$SSH_CMD" \
  "${BLOBS_DIR}/" \
  "${USER}@${BLOB_HOST}:${BLOB_REMOTE}"

echo "==> rsync index.json[.sig] last → ${USER}@${INDEX_HOST}:${INDEX_REMOTE}"
ROOT_FILES=("${INDEX_TREE}/index.json")
[ -f "${INDEX_TREE}/index.json.sig" ] && ROOT_FILES+=("${INDEX_TREE}/index.json.sig")
rsync -az \
  -e "$SSH_CMD" \
  "${ROOT_FILES[@]}" \
  "${USER}@${INDEX_HOST}:${INDEX_REMOTE}"

echo "publish complete"
