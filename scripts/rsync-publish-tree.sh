# Push a prepared publish tree to the origin box, in a two-phase
# sequence that keeps the snapshot model intact (DISTRIBUTION.md
# §Snapshot-consistency).
#
# Sequence:
#   1. Push immutable, additive content first:
#        - blobs   → /srv/blobs/                                   (content-addressed by sha)
#        - the new versioned snapshot
#                  → /srv/index/versions/<V>/targets/<target>/sections/...
#                  → /srv/index/versions/<V>/targets/<target>/manifests/...
#      Both sections and manifests live under the per-publish
#      /versions/<V>/ tree (this used to be split, with manifests in a
#      shared /srv/index/targets/ tree — until a republish of the same
#      tag overwrote a manifest file the prior root's signed section
#      was still pinned to, breaking clients holding the prior root).
#      Nothing in this phase is observable to clients yet because the
#      live root.json hasn't been replaced — it still points at the
#      previous version's URLs.
#   2. Replace /srv/index/index.json and .sig atomically (write to .new,
#      then mv -T). This is the only mutation visible to clients; from
#      this point new fetches see the new root, which references the
#      section/manifest/blob URLs that landed in phase 1.
#   3. (Implicit) Old /srv/index/versions/<V-1>/... directories stay
#      in place so clients with a cached old root finish their sync
#      from the matching snapshot. Old manifests under the legacy
#      /srv/index/targets/<t>/manifests/ tree (from before this script
#      moved them under /versions/) also stay in place for cached old
#      roots that referenced the unversioned paths. GC of versions
#      older than the root's must-revalidate TTL is a separate cron
#      concern.
#
# Args:
#   $1 — index tree dir (must contain index.json[, .sig] and versions/
#        — i.e. the layout index.nix produces minus blobs/)
#   $2 — blobs dir (the blobs/ subtree, content-addressed files)
#   $3 — SSH destination (a hostname that resolves directly to the box,
#        e.g. origin.bougie.tools — NOT the public index/blob hostnames,
#        which may be CDN-fronted and refuse SSH). The same SSH host is
#        used for every phase; the index and blob trees live on the
#        same physical box, served by two separate nginx vhosts.
#
# Env:
#   PUBLISH_SSH_KEY   — SSH private key contents. Required.
#   PUBLISH_SSH_USER  — remote user (default: deploy)
#   INDEX_REMOTE_ROOT — index doc root on the box (default: /srv/index).
#                       Must match nginx's `root` for the index vhost
#                       (~/infra/hosts/origin/nginx.nix). When migrating
#                       from the symlink-flip layout, replace the
#                       existing /srv/index symlink with a real
#                       directory before the first run.
#   BLOB_REMOTE_PATH  — blobs root on the box (default: /srv/blobs/)

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <index-tree-dir> <blobs-dir> <ssh-host>" >&2
  echo "       <ssh-host> must resolve directly to the origin box" >&2
  echo "       (CDN-fronted public hostnames refuse SSH)." >&2
  exit 2
fi

INDEX_TREE="$1"
BLOBS_DIR="$2"
SSH_HOST="$3"
USER="${PUBLISH_SSH_USER:-deploy}"
INDEX_ROOT="${INDEX_REMOTE_ROOT:-/srv/index}"
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
DEST="${USER}@${SSH_HOST}"

# ---- Phase 1a: blobs (content-addressed, additive) ----
echo "==> [1a] rsync blobs → ${DEST}:${BLOB_REMOTE}"
rsync -az --chmod=D755,F644 \
  -e "$SSH_CMD" \
  "${BLOBS_DIR}/" \
  "${DEST}:${BLOB_REMOTE}"

# ---- Phase 1b: versioned snapshot (sections + manifests) ----
# versions/<V>/ is a fresh path nobody serves yet because the live
# root still names the previous <V-1>. Landing it before the root flip
# means the new root never references missing sections or manifests.
# Both kinds of files live under the same /versions/<V>/ tree (see
# header comment for why); this single rsync push covers them both.
if [ -d "${INDEX_TREE}/versions" ]; then
  echo "==> [1b] rsync versions → ${DEST}:${INDEX_ROOT}/versions/"
  $SSH_CMD "${DEST}" "mkdir -p ${INDEX_ROOT}/versions"
  rsync -az --chmod=D755,F644 \
    -e "$SSH_CMD" \
    "${INDEX_TREE}/versions/" \
    "${DEST}:${INDEX_ROOT}/versions/"
fi

# ---- Phase 2: atomic root replacement ----
# Stage index.json (and .sig if present) as .new, then rename(2)-replace
# the live file. Each rename is atomic; together the visible state goes
# from {old root, old sig} to {new root, new sig} with at most one
# revalidation window of inconsistency. (Clients revalidate the root
# every ~30s by must-revalidate, so a sig fetched a moment after the
# root is overwhelmingly likely to be the matching one.)
echo "==> [2]  atomic root replace → ${DEST}:${INDEX_ROOT}/index.json"
rsync -az --chmod=D755,F644 \
  -e "$SSH_CMD" \
  "${INDEX_TREE}/index.json" \
  "${DEST}:${INDEX_ROOT}/index.json.new"
$SSH_CMD "${DEST}" \
  "mv -f ${INDEX_ROOT}/index.json.new ${INDEX_ROOT}/index.json"

if [ -f "${INDEX_TREE}/index.json.sig" ]; then
  rsync -az --chmod=D755,F644 \
    -e "$SSH_CMD" \
    "${INDEX_TREE}/index.json.sig" \
    "${DEST}:${INDEX_ROOT}/index.json.sig.new"
  $SSH_CMD "${DEST}" \
    "mv -f ${INDEX_ROOT}/index.json.sig.new ${INDEX_ROOT}/index.json.sig"
fi

NEW_VERSION="$(jq -r '.version' "${INDEX_TREE}/index.json" 2>/dev/null || echo "<unknown>")"
echo "publish complete (now serving version: ${NEW_VERSION})"
