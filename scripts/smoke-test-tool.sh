#!/usr/bin/env bash
# Smoke-test a tool tarball post tool-closure split (UNBUNDLE_PLAN.md).
#
# Lays out a temporary $BOUGIE_HOME-shape store/ tree, extracts the
# tool tarball into store/<tag>/, then for each closure entry in the
# manifest extracts the matching per-store-path tarball into store/
# alongside, and finally for each requires_tools entry extracts the
# depended-on tool tarball and creates the link_into symlink. Runs
# the tool's primary binary with the version-style probe given via
# --probe to verify dlopen + runtime exec all work without the
# original bundled-store baking.
#
# Usage:
#   smoke-test-tool.sh <tool-tarball> <release-dir> <binary> [args...]
#                      [--requires <tool-tarball>]...
#
# Arguments:
#   <tool-tarball>   path to the .tar.zst this script verifies
#   <release-dir>    directory containing the closure store-path tarballs
#                    (one per <storeName>.tar.zst). Typically the
#                    pbs-release-<tool>/ output the index pipeline
#                    consumes. The closure entries' urls reference these
#                    by sha256, but we look up by storeName here since
#                    the release-dir filenames embed the storeName
#                    verbatim.
#   <binary>         relative path under install/ of the binary to run
#                    (e.g. "bin/mariadb-admin", "bin/redis-cli")
#   args             additional argv to pass to the binary (typically
#                    "--version" or "--help")
#
# Options:
#   --requires <tool-tarball>
#                    repeatable. For each requires_tools[] entry on the
#                    outer tool, pass the matching inner tool tarball
#                    here. The script extracts each and creates the
#                    link_into symlink before running the probe.
#
# Outputs: grouped progress to stdout; exits non-zero on any failure.

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 <tool-tarball> <release-dir> <binary> [args...] [--requires <tool-tarball>]..." >&2
  exit 1
fi

TARBALL="$1"; shift
RELEASE_DIR="$1"; shift
BINARY="$1"; shift

# Collect --requires args into REQUIRES; everything else is binary args.
REQUIRES=()
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --requires)
      [ $# -ge 2 ] || { echo "FATAL: --requires needs an argument" >&2; exit 1; }
      REQUIRES+=("$2")
      shift 2
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

smoke_root="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$smoke_root"' EXIT

# Shared store: mirrors $BOUGIE_HOME/store. Every closure entry's
# tarball extracts to a sibling here, and the tool's tarball extracts
# under its own <tag> subdirectory inside the same root so the
# $ORIGIN/../store/<lib>-<ver>-<hash>/lib RPATHs resolve correctly.
store="$smoke_root/store"
mkdir -p "$store"

# Resolve the outer tool's tag from the manifest sitting next to the
# tarball (same flat-dir shape the release derivations produce).
manifest="${TARBALL%.tar.zst}.json"
[ -f "$manifest" ] || { echo "FATAL: manifest sidecar missing: $manifest" >&2; exit 1; }
tag="$(jq -r '.tag' "$manifest")"

echo "::group::extract tool tarball ($tag)"
mkdir -p "$store/$tag"
# Tarball contents live under a leading `install/` dir; strip it so
# install/bin/foo lands at store/<tag>/bin/foo — matching the layout
# bougie's client materializes on disk.
tar --use-compress-program=unzstd \
    --strip-components=1 \
    -xf "$TARBALL" -C "$store/$tag"
echo "::endgroup::"

echo "::group::extract closure entries"
# For each closure entry, locate the matching store-path tarball in
# RELEASE_DIR by storeName and extract into the shared store. The
# tarball wraps its contents in `<storeName>/`, so extracting into
# `$store/` lays it down at `$store/<storeName>/...` — exactly where
# the tool binary's RPATH expects it.
closure_count="$(jq '.closure | length' "$manifest")"
if [ "$closure_count" -gt 0 ]; then
  for i in $(seq 0 $((closure_count - 1))); do
    entry="$(jq -c ".closure[$i]" "$manifest")"
    name="$(echo "$entry" | jq -r '.name')"
    ver="$(echo "$entry" | jq -r '.version')"
    hash="$(echo "$entry" | jq -r '.hash')"
    storeName="$name-$ver-$hash"
    sp_tarball="$RELEASE_DIR/$storeName.tar.zst"
    if [ ! -f "$sp_tarball" ]; then
      echo "FATAL: closure entry $storeName: tarball missing at $sp_tarball" >&2
      echo "  Release dir contents:" >&2
      ls -la "$RELEASE_DIR" >&2
      exit 1
    fi
    echo "  extracting $storeName"
    tar --use-compress-program=unzstd -xf "$sp_tarball" -C "$store"
    [ -d "$store/$storeName" ] || {
      echo "FATAL: $sp_tarball did not extract to $store/$storeName" >&2
      exit 1
    }
  done
else
  echo "  (no closure entries)"
fi
echo "::endgroup::"

# Materialize the per-entry peer symlinks the bougie client would
# create at install time: $store/<tag>/store/<lib>-<ver>-<hash> →
# ../../<lib>-<ver>-<hash>. The tool binary's RPATH walks through
# these to find each closure lib in the shared $store pool.
if [ "$closure_count" -gt 0 ]; then
  echo "::group::materialize closure peer symlinks"
  mkdir -p "$store/$tag/store"
  for i in $(seq 0 $((closure_count - 1))); do
    entry="$(jq -c ".closure[$i]" "$manifest")"
    name="$(echo "$entry" | jq -r '.name')"
    ver="$(echo "$entry" | jq -r '.version')"
    hash="$(echo "$entry" | jq -r '.hash')"
    storeName="$name-$ver-$hash"
    ln -sf "../../$storeName" "$store/$tag/store/$storeName"
  done
  echo "::endgroup::"
fi

# Walk requires_tools[] and lay down the inner-tool installs +
# link_into symlinks. The --requires args are matched by tag, so
# order doesn't matter — but every requires_tools[] entry must have
# a corresponding --requires <inner-tarball>. The inner tool's own
# closure[] entries also need extracting + peer-symlinking; the
# script looks for their store-path tarballs in the inner tarball's
# parent directory (i.e. the inner tool's release dir).
echo "::group::resolve requires_tools"
requires_count="$(jq '.requires_tools // [] | length' "$manifest")"
if [ "$requires_count" -gt 0 ]; then
  declare -A requires_by_tag
  for rt in "${REQUIRES[@]:-}"; do
    rt_manifest="${rt%.tar.zst}.json"
    [ -f "$rt_manifest" ] || { echo "FATAL: --requires manifest missing: $rt_manifest" >&2; exit 1; }
    rt_tag="$(jq -r '.tag' "$rt_manifest")"
    requires_by_tag["$rt_tag"]="$rt"
  done

  for i in $(seq 0 $((requires_count - 1))); do
    entry="$(jq -c ".requires_tools[$i]" "$manifest")"
    req_name="$(echo "$entry" | jq -r '.name')"
    req_tag="$(echo "$entry" | jq -r '.tag')"
    link_into="$(echo "$entry" | jq -r '.link_into')"
    inner_tarball="${requires_by_tag[$req_tag]:-}"
    if [ -z "$inner_tarball" ]; then
      echo "FATAL: missing --requires for $req_name@$req_tag" >&2
      echo "  outer tool depends on this; pass --requires <inner-tarball> on the CLI" >&2
      exit 1
    fi
    echo "  extracting inner tool $req_tag"
    mkdir -p "$store/$req_tag"
    tar --use-compress-program=unzstd \
        --strip-components=1 \
        -xf "$inner_tarball" -C "$store/$req_tag"

    # Inner tool's closure: extract each entry's store-path tarball
    # from the inner tool's release dir (the directory containing
    # the inner tarball) into the shared store, then materialize the
    # inner-side peer symlinks so the inner binaries' RPATHs resolve.
    # Same shape the outer-tool closure loop above does, just keyed
    # off the inner manifest.
    inner_release_dir="$(dirname "$inner_tarball")"
    inner_manifest="${inner_tarball%.tar.zst}.json"
    inner_closure_count="$(jq '.closure | length' "$inner_manifest")"
    if [ "$inner_closure_count" -gt 0 ]; then
      mkdir -p "$store/$req_tag/store"
      for ci in $(seq 0 $((inner_closure_count - 1))); do
        c_entry="$(jq -c ".closure[$ci]" "$inner_manifest")"
        c_name="$(echo "$c_entry" | jq -r '.name')"
        c_ver="$(echo "$c_entry" | jq -r '.version')"
        c_hash="$(echo "$c_entry" | jq -r '.hash')"
        c_storeName="$c_name-$c_ver-$c_hash"
        c_sp_tarball="$inner_release_dir/$c_storeName.tar.zst"
        if [ ! -f "$c_sp_tarball" ]; then
          echo "FATAL: inner closure entry $c_storeName: tarball missing at $c_sp_tarball" >&2
          exit 1
        fi
        # No-op if a sibling outer-tool entry already extracted this
        # storeName into the shared store — tar will overwrite with
        # bit-identical content thanks to the content-addressed
        # storeName matching.
        tar --use-compress-program=unzstd -xf "$c_sp_tarball" -C "$store"
        ln -sf "../../$c_storeName" "$store/$req_tag/store/$c_storeName"
      done
    fi

    if [ -n "$link_into" ]; then
      # Symlink under the outer install root, relative to the outer.
      # store/<outer-tag>/<link_into> → ../<inner-tag>
      target_link="$store/$tag/$link_into"
      # Defend against the slot already existing (we just extracted
      # the outer tarball; if upstream left a directory at the slot
      # name, bail loudly — the slot must be free).
      if [ -e "$target_link" ] || [ -L "$target_link" ]; then
        echo "FATAL: link_into slot already exists at $target_link" >&2
        echo "  outer tarball should not ship anything at this path" >&2
        exit 1
      fi
      ln -s "../$req_tag" "$target_link"
    fi
  done
else
  echo "  (no requires_tools entries)"
fi
echo "::endgroup::"

# Run the probe binary. It's the closest thing to dlopen + RPATH
# walk + cross-tarball symlink resolution we get without a full
# end-to-end bougie install — every failure mode from a missing
# closure lib to a broken link_into surfaces as a non-zero exit
# from this command.
bin_path="$store/$tag/$BINARY"
[ -x "$bin_path" ] || { echo "FATAL: $bin_path not present/executable" >&2; exit 1; }

echo "::group::probe: $BINARY ${ARGS[*]}"
"$bin_path" "${ARGS[@]}"
echo "::endgroup::"

echo "smoke-test-tool: $tag — ok"
