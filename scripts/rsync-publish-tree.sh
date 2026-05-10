# Push a prepared publish tree to the two-vhost origin described in
# DISTRIBUTION.md "Hosting", in a three-phase sequence that keeps the
# snapshot model intact (DISTRIBUTION.md §Snapshot-consistency).
#
# Sequence:
#   1. Push immutable, additive content first:
#        - blobs   → /srv/blobs/        (content-addressed by sha)
#        - manifests → /srv/targets/<target>/manifests/...  (paths
#                      embed the tag, so additive across publishes)
#        - the new versioned section tree
#                  → /srv/versions/<V>/targets/<target>/sections/...
#      Nothing in this phase is observable to clients yet because the
#      live root.json hasn't been replaced — it still points at the
#      previous version's section URLs.
#   2. Replace /srv/index.json and /srv/index.json.sig atomically
#      (write to .new, then mv -T). This is the only mutation visible
#      to clients; from this point new fetches see the new root, which
#      references the section/manifest/blob URLs that landed in phase 1.
#   3. (Implicit) Old /srv/versions/<V-1>/... directories stay in place
#      so clients with a cached old root finish their sync from the
#      matching snapshot. GC of versions older than the root's
#      must-revalidate TTL is a separate cron concern.
#
# Args:
#   $1 — index tree dir (must contain index.json[, .sig], versions/,
#        targets/, blobs/ — i.e. the layout index.nix produces)
#   $2 — blobs dir (the blobs/ subtree, content-addressed files)
#   $3 — index hostname (e.g. index.example.com)
#   $4 — blob hostname  (e.g. blobs.example.com)
#
# Env:
#   PUBLISH_SSH_KEY  — SSH private key contents. Required.
#   PUBLISH_SSH_USER — remote user (default: deploy)
#   INDEX_REMOTE_ROOT — remote index doc root (default: /srv)
#   BLOB_REMOTE_PATH  — remote blobs root (default: /srv/blobs/)

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <index-tree-dir> <blobs-dir> <index-host> <blob-host>" >&2
  exit 2
fi

INDEX_TREE="$1"
BLOBS_DIR="$2"
INDEX_HOST="$3"
BLOB_HOST="$4"
USER="${PUBLISH_SSH_USER:-deploy}"
INDEX_ROOT="${INDEX_REMOTE_ROOT:-/srv}"
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

# ---- Phase 1a: blobs (content-addressed, additive) ----
echo "==> [1a] rsync blobs → ${USER}@${BLOB_HOST}:${BLOB_REMOTE}"
rsync -az --chmod=D755,F644 \
  -e "$SSH_CMD" \
  "${BLOBS_DIR}/" \
  "${USER}@${BLOB_HOST}:${BLOB_REMOTE}"

# ---- Phase 1b: shared manifest tree (paths embed the tag, additive) ----
# The on-disk index tree contains targets/<target>/manifests/... — a
# shared, content-addressed-by-tag namespace that survives across
# publishes. Sync only this subtree; do NOT include the section tree
# (sections live under versions/<V>/, handled in phase 1c) and do NOT
# include the root yet (handled in phase 2).
if [ -d "${INDEX_TREE}/targets" ]; then
  echo "==> [1b] rsync manifests → ${USER}@${INDEX_HOST}:${INDEX_ROOT}/targets/"
  $SSH_CMD "${USER}@${INDEX_HOST}" "mkdir -p ${INDEX_ROOT}/targets"
  rsync -az --chmod=D755,F644 \
    -e "$SSH_CMD" \
    "${INDEX_TREE}/targets/" \
    "${USER}@${INDEX_HOST}:${INDEX_ROOT}/targets/"
fi

# ---- Phase 1c: versioned section tree (immutable URL per publish) ----
# versions/<V>/ is a fresh path nobody serves yet because the live
# root still names the previous <V-1>. Landing it before the root flip
# means the new root never references missing sections.
if [ -d "${INDEX_TREE}/versions" ]; then
  echo "==> [1c] rsync versions → ${USER}@${INDEX_HOST}:${INDEX_ROOT}/versions/"
  $SSH_CMD "${USER}@${INDEX_HOST}" "mkdir -p ${INDEX_ROOT}/versions"
  rsync -az --chmod=D755,F644 \
    -e "$SSH_CMD" \
    "${INDEX_TREE}/versions/" \
    "${USER}@${INDEX_HOST}:${INDEX_ROOT}/versions/"
fi

# ---- Phase 2: atomic root replacement ----
# Stage index.json (and .sig if present) as .new, then rename(2)-replace
# the live file. Each rename is atomic; together the visible state goes
# from {old root, old sig} to {new root, new sig} with at most one
# revalidation window of inconsistency. (Clients revalidate the root
# every ~30s by must-revalidate, so a sig fetched a moment after the
# root is overwhelmingly likely to be the matching one.)
echo "==> [2]  atomic root replace → ${USER}@${INDEX_HOST}:${INDEX_ROOT}/index.json"
rsync -az --chmod=D755,F644 \
  -e "$SSH_CMD" \
  "${INDEX_TREE}/index.json" \
  "${USER}@${INDEX_HOST}:${INDEX_ROOT}/index.json.new"
$SSH_CMD "${USER}@${INDEX_HOST}" \
  "mv -f ${INDEX_ROOT}/index.json.new ${INDEX_ROOT}/index.json"

if [ -f "${INDEX_TREE}/index.json.sig" ]; then
  rsync -az --chmod=D755,F644 \
    -e "$SSH_CMD" \
    "${INDEX_TREE}/index.json.sig" \
    "${USER}@${INDEX_HOST}:${INDEX_ROOT}/index.json.sig.new"
  $SSH_CMD "${USER}@${INDEX_HOST}" \
    "mv -f ${INDEX_ROOT}/index.json.sig.new ${INDEX_ROOT}/index.json.sig"
fi

NEW_VERSION="$(jq -r '.version' "${INDEX_TREE}/index.json" 2>/dev/null || echo "<unknown>")"
echo "publish complete (now serving version: ${NEW_VERSION})"
