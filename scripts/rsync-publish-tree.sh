# Push a prepared publish tree to the two-vhost origin described in
# DISTRIBUTION.md "Hosting", with an atomic version-flip so the index
# tree is never observed in a half-applied state.
#
# Sequence:
#   1. rsync blobs → /srv/blobs/ (additive, content-addressed; existing
#      files are no-ops, new ones land but nothing references them yet
#      because the live root hasn't flipped)
#   2. rsync the entire new index tree → /srv/index-versions/<VERSION>/
#      (a fresh path nobody serves yet; live tree is untouched)
#   3. atomic symlink flip on the remote: ln -s + mv -T turns into one
#      rename(2), so observers see either the old version or the new
#      version — never any in-between state. Old version dirs stay
#      around so clients with cached old roots keep working until they
#      refresh; GC of old versions is a separate cron concern.
#
# Args:
#   $1 — index tree dir (must contain index.json[, .sig], targets/, ...)
#   $2 — blobs dir (the blobs/ subtree, content-addressed files)
#   $3 — index hostname (e.g. index.example.com)
#   $4 — blob hostname  (e.g. blobs.example.com)
#
# Env:
#   PUBLISH_SSH_KEY     — SSH private key contents. Required.
#   PUBLISH_SSH_USER    — remote user (default: deploy)
#   PUBLISH_VERSION     — version tag for the new index dir
#                         (default: $(date -u +%Y%m%dT%H%M%SZ))
#   INDEX_LIVE_PATH     — symlink that nginx serves (default: /srv/index)
#   INDEX_VERSIONS_ROOT — versioned-trees parent (default: /srv/index-versions)
#   BLOB_REMOTE_PATH    — remote blobs root (default: /srv/blobs/)

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <index-tree-dir> <blobs-dir> <index-host> <blob-host>" >&2
  exit 2
fi

INDEX_TREE="$1"
BLOBS_DIR="$2"
INDEX_HOST="$3"
BLOB_HOST="$4"
USER="${PUBLISH_SSH_USER:-deploy}"
VERSION="${PUBLISH_VERSION:-$(date -u +%Y%m%dT%H%M%SZ)}"
LIVE_PATH="${INDEX_LIVE_PATH:-/srv/index}"
VERSIONS_ROOT="${INDEX_VERSIONS_ROOT:-/srv/index-versions}"
BLOB_REMOTE="${BLOB_REMOTE_PATH:-/srv/blobs/}"
NEW_VERSION_DIR="${VERSIONS_ROOT}/${VERSION}"

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

# 1. Blobs first. They're content-addressed and additive: new sha256s
#    appear, existing ones are no-ops. Nothing references the new ones
#    until the index flip in step 3, so this can't be observed
#    inconsistently from a client's perspective.
echo "==> rsync blobs → ${USER}@${BLOB_HOST}:${BLOB_REMOTE}"
rsync -az --chmod=D755,F644 \
  -e "$SSH_CMD" \
  "${BLOBS_DIR}/" \
  "${USER}@${BLOB_HOST}:${BLOB_REMOTE}"

# 2. Stage the new index tree at a fresh versioned path. The live
#    symlink still points at the previous version, so this directory is
#    invisible to clients until step 3.
echo "==> rsync index tree → ${USER}@${INDEX_HOST}:${NEW_VERSION_DIR}/"
$SSH_CMD "${USER}@${INDEX_HOST}" "mkdir -p ${VERSIONS_ROOT}"
rsync -az --chmod=D755,F644 \
  -e "$SSH_CMD" \
  "${INDEX_TREE}/" \
  "${USER}@${INDEX_HOST}:${NEW_VERSION_DIR}/"

# 3. Atomic flip: create the new symlink under a temporary name, then
#    rename(2)-replace the live symlink. mv -T (--no-target-directory)
#    is the key — without it, a directory-target rename would descend.
#    Replacement is one syscall; observers see either the old or new
#    target, never a missing or half-built tree.
echo "==> atomic symlink flip → ${LIVE_PATH} → ${NEW_VERSION_DIR}"
$SSH_CMD "${USER}@${INDEX_HOST}" \
  "ln -s ${NEW_VERSION_DIR} ${LIVE_PATH}.new && mv -T ${LIVE_PATH}.new ${LIVE_PATH}"

echo "publish complete (now serving: ${VERSION})"
