#!/usr/bin/env bash
# Finalize a Darwin staging tree: rewrite install names + LC_LOAD_DYLIB
# entries to be relocatable, add per-binary @loader_path/… store-path
# rpaths, run shared text-file detoxification, ad-hoc codesign, then
# audit. Operates in-place on $PBS_INSTALL.
#
# Phase 2: each Mach-O gets LC_RPATH entries pointing at
# @loader_path/<rel>/store/<storeName>/lib for each store path that
# provides one of its LC_LOAD_DYLIB sonames (parallel to the Linux
# $ORIGIN/../store/<name>/lib RPATH strategy).
#
# Why ad-hoc codesign at the end:
#   On aarch64 macOS the linker auto-emits an ad-hoc signature on every
#   Mach-O. install_name_tool mutations invalidate that signature, after
#   which AMFI / syspolicyd refuses to load the binary on Sequoia+, and
#   the user sees a SIGKILL with no explanation. PBS hits this bug; uv
#   hits it; PR #17123 to add post-install codesigning to uv was closed
#   unmerged. We do it here at build time so the artifact ships
#   pre-validated. Ad-hoc signing requires no Apple Developer account.
#
# Order matters: install_name_tool walk → strip → codesign. Stripping
# also invalidates signatures, so codesign MUST come last.

set -euo pipefail

: "${PBS_INSTALL:?}"
: "${PBS_FINALIZE_COMMON:?must be set by tree.nix}"
: "${PBS_STORE_MANIFEST:?must be set by tree.nix}"

source "$PBS_FINALIZE_COMMON"

# Tools live in /usr/bin on every macOS install (CommandLineTools or
# full Xcode). Use absolute paths so we don't depend on a sandboxed
# PATH ordering.
INSTALL_NAME_TOOL=/usr/bin/install_name_tool
OTOOL=/usr/bin/otool
CODESIGN=/usr/bin/codesign

is_macho() {
  file -b "$1" 2>/dev/null | grep -q '^Mach-O'
}

is_dylib() {
  file -b "$1" 2>/dev/null | grep -q 'Mach-O.* dynamically linked shared library'
}

# ---- Build soname → storeName lookup table (Darwin) ----
# Same structure as finalize-linux.sh. Uses LC_ID_DYLIB (otool -D) to
# get the canonical install name (analogous to DT_SONAME on Linux).

declare -A PBS_SONAME_STORE

SYSTEM_DYLIBS_PREFIX=(
  "/usr/lib/" "/System/"
)

_is_system_dylib() {
  local name="$1"
  for pfx in "${SYSTEM_DYLIBS_PREFIX[@]}"; do
    [[ "$name" == "${pfx}"* ]] && return 0
  done
  return 1
}

_build_soname_map() {
  echo
  echo "=== finalize: building soname→storeName map (Darwin) ==="
  while IFS=' ' read -r storeName nixPath; do
    [ -n "$storeName" ] || continue
    [ -d "$nixPath/lib" ] || continue
    while IFS= read -r -d '' dylib; do
      [ -L "$dylib" ] && continue
      is_dylib "$dylib" || continue
      local soname
      soname="$("$OTOOL" -D "$dylib" 2>/dev/null | tail -n1 | tr -d ' ')"
      [ -n "$soname" ] || continue
      _is_system_dylib "$soname" && continue
      local base
      base="$(basename "$soname")"
      PBS_SONAME_STORE["$base"]="$storeName"
    done < <(find "$nixPath/lib" -name "*.dylib" -print0 2>/dev/null)
  done < "$PBS_STORE_MANIFEST"

  echo "  mapped ${#PBS_SONAME_STORE[@]} bundled sonames"
}

# ---- Compute LC_RPATH set for one Mach-O ----
# Writes a newline-separated list of @loader_path-relative rpath strings
# into the global _RPATHS_RESULT. Must be called in the main shell, not
# a subshell — bash associative arrays (PBS_SONAME_STORE) don't propagate
# into command-substitution subshells, so a `<( _compute_rpaths )` form
# would see an empty soname index and produce zero rpath entries (which
# is exactly what broke the macOS leg silently in CI).
_compute_rpaths() {
  local f="$1"
  _RPATHS_RESULT=""

  local rel="${f#$PBS_INSTALL/}"
  local dir_part
  dir_part="$(dirname "$rel")"
  local hops
  hops=$(echo "$dir_part" | tr -cd '/' | wc -c)
  hops=$((hops + 1))

  local prefix=""
  local i
  for ((i = 0; i < hops; i++)); do
    prefix="${prefix}../"
  done
  prefix="${prefix%/}"

  declare -A seen_stores
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      "/usr/lib/"*|"/System/"*|"@rpath/"*|"@loader_path/"*|"@executable_path/"*) ;;
      *) local base; base="$(basename "$dep")"
         local sn="${PBS_SONAME_STORE[$base]:-}"
         [ -n "$sn" ] && seen_stores["$sn"]=1 ;;
    esac
  done < <("$OTOOL" -L "$f" 2>/dev/null | awk 'NR>1 {print $1}')

  for sn in $(echo "${!seen_stores[@]}" | tr ' ' '\n' | sort); do
    _RPATHS_RESULT+="@loader_path/${prefix}/store/${sn}/lib"$'\n'
  done
}

# ---- Darwin phases ----

darwin_install_name_walk() {
  echo
  echo "=== finalize: install_name_tool walk ==="
  patched=0
  walk_files _install_name_one
  echo "patched $patched Mach-Os"
}
_install_name_one() {
  local f="$1"
  is_macho "$f" || return 0

  # 1. Dylibs: rewrite LC_ID_DYLIB to @rpath/<basename>.
  if is_dylib "$f"; then
    local base
    base="$(basename "$f")"
    "$INSTALL_NAME_TOOL" -id "@rpath/$base" "$f"
  fi

  # 2. Rewrite every LC_LOAD_DYLIB that isn't already portable.
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      "/usr/lib/"*|"/System/"*|"@rpath/"*|"@loader_path/"*|"@executable_path/"*) ;;
      /*|*/*)
        local depbase
        depbase="$(basename "$dep")"
        "$INSTALL_NAME_TOOL" -change "$dep" "@rpath/$depbase" "$f"
        ;;
      *)
        "$INSTALL_NAME_TOOL" -change "$dep" "@rpath/$dep" "$f"
        ;;
    esac
  done < <("$OTOOL" -L "$f" 2>/dev/null | awk 'NR>1 {print $1}')

  # 3. Replace all existing LC_RPATH entries with per-binary store-path set.
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    "$INSTALL_NAME_TOOL" -delete_rpath "$rp" "$f" 2>/dev/null || true
  done < <("$OTOOL" -l "$f" 2>/dev/null \
            | awk '/cmd LC_RPATH/{flag=1; next} flag && /path /{print $2; flag=0}')

  # Add one LC_RPATH entry per store path providing a dependency.
  # _compute_rpaths writes to _RPATHS_RESULT in the current shell so it
  # can read PBS_SONAME_STORE (bash associative arrays don't cross
  # subshells, including command-substitution / process-substitution).
  _compute_rpaths "$f"
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    "$INSTALL_NAME_TOOL" -add_rpath "$rp" "$f" 2>/dev/null || true
  done <<< "$_RPATHS_RESULT"

  # Always add @loader_path as a fallback so sibling dylibs in the same
  # directory resolve without an explicit per-entry (e.g. PHP extension
  # .so files that dlopen each other).
  "$INSTALL_NAME_TOOL" -add_rpath "@loader_path" "$f" 2>/dev/null || true

  patched=$((patched + 1))
}

darwin_strip_toolchain_leaks() {
  for f in "$PBS_INSTALL/bin/php-config" "$PBS_INSTALL/include/php/main/build-defs.h"; do
    [ -f "$f" ] || continue
    sed -i -E 's| -L/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/lib||g' "$f"
    sed -i -E 's| -isystem +/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/include||g' "$f"
    sed -i -E 's|-isystem +/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/include||g' "$f"
  done
}

darwin_strip_machos() {
  echo
  echo "=== finalize: strip Mach-Os ==="
  walk_files _darwin_strip_one
}
_darwin_strip_one() {
  is_macho "$1" || return 0
  strip -x "$1" 2>/dev/null || true
}

darwin_codesign() {
  echo
  echo "=== finalize: ad-hoc codesign ==="
  signed=0
  walk_files _codesign_one
  echo "signed $signed Mach-Os"
}
_codesign_one() {
  is_macho "$1" || return 0
  "$CODESIGN" --force --sign - --preserve-metadata=entitlements,requirements,flags "$1"
  signed=$((signed + 1))
}

darwin_audit_rpath_allowlist() {
  # Every Mach-O's LC_RPATH must be either @loader_path or
  # @loader_path/<rel>/store/<storeName>/lib. No build-host paths.
  local bad=""
  walk_files _audit_rpath
  if [ -n "$bad" ]; then
    echo "FAIL: non-allowlisted LC_RPATH:" >&2
    echo "$bad" >&2
    return 1
  fi
}
_audit_rpath() {
  is_macho "$1" || return 0
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    case "$rp" in
      "@loader_path") ;;
      "@loader_path/"*/store/*/lib) ;;
      *) bad+="$1: $rp"$'\n' ;;
    esac
  done < <("$OTOOL" -l "$1" 2>/dev/null \
            | awk '/cmd LC_RPATH/{flag=1; next} flag && /path /{print $2; flag=0}')
}

darwin_audit_load_dylib() {
  local bad=""
  walk_files _audit_load
  if [ -n "$bad" ]; then
    echo "FAIL: non-portable LC_LOAD_DYLIB:" >&2
    echo "$bad" >&2
    return 1
  fi
}
_audit_load() {
  is_macho "$1" || return 0
  while IFS= read -r dep; do
    case "$dep" in
      "@rpath/"*|"/usr/lib/"*|"/System/"*|"@loader_path/"*|"@executable_path/"*|"") ;;
      *) bad+="$1: LC_LOAD_DYLIB $dep"$'\n' ;;
    esac
  done < <("$OTOOL" -L "$1" 2>/dev/null | awk 'NR>1 {print $1}')
}

darwin_audit_codesign() {
  local bad=""
  walk_files _audit_codesign_one
  if [ -n "$bad" ]; then
    echo "FAIL: invalid or missing codesign:" >&2
    echo "$bad" >&2
    return 1
  fi
}
_audit_codesign_one() {
  is_macho "$1" || return 0
  if ! "$CODESIGN" --verify --strict "$1" 2>/dev/null; then
    bad+="$1"$'\n'
  fi
}

# ---- Phase dispatch ----

_build_soname_map

run_phases \
  darwin_install_name_walk \
  common_remove_la_files \
  common_detoxify_pc_files \
  common_detoxify_text_files \
  common_rewrite_phpize_prefix \
  darwin_strip_toolchain_leaks \
  darwin_strip_machos \
  darwin_codesign \
  common_audit_no_nix_store_text \
  darwin_audit_rpath_allowlist \
  darwin_audit_load_dylib \
  darwin_audit_codesign
