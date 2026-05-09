#!/usr/bin/env bash
# Serve a merged distribution tree locally and run validate-index.sh against it.
#
# Usage: validate-publish-tree.sh <merged-tree-dir>
#
# Inputs:
#   $1  directory to serve (must contain index.json, targets/, blobs/)
#
# Environment:
#   VALIDATE_INDEX_SH  path to validate-index.sh
#                      (default: tests/validate-index.sh relative to this script)
#
# Spins up python3 -m http.server on a free port, calls validate-index.sh,
# then kills the server. Exits with validate-index.sh's exit code.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <merged-tree-dir>" >&2
  exit 1
fi

MERGED_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATE_INDEX_SH="${VALIDATE_INDEX_SH:-$SCRIPT_DIR/../tests/validate-index.sh}"

if [ ! -f "$VALIDATE_INDEX_SH" ]; then
  echo "FAIL: validate-index.sh not found at $VALIDATE_INDEX_SH" >&2
  echo "      Set VALIDATE_INDEX_SH to its absolute path." >&2
  exit 1
fi

# Pick a free port by binding to :0 and reading the assigned port
PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("", 0))
print(s.getsockname()[1])
s.close()
')"

python3 -m http.server "$PORT" --directory "$MERGED_DIR" &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT

# Give the server a moment to bind before the first curl
sleep 1

set +e
bash "$VALIDATE_INDEX_SH" "http://127.0.0.1:${PORT}"
EXIT_CODE=$?
set -e

exit "$EXIT_CODE"
