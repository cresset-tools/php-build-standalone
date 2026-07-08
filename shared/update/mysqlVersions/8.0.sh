#!/usr/bin/env bash
# MySQL 8.0 reached End of Life around April 2026; 8.0.46 is the final
# release of the line and no further patches will ship. There is nothing
# to bump, so this updater is a deliberate no-op — we keep 8.0 pinned at
# its terminal version until the whole line is retired from the matrix.
#
# (Kept as an explicit script rather than deleted so `nix run .#update`
# still reports the 8.0 key instead of silently skipping it.)
. "$(dirname "$0")/../../../scripts/update-lib.sh"

pbs_emit_noop
