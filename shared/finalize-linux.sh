#!/usr/bin/env bash
# Finalize the staging tree on Linux: strip ELFs, patchelf RPATH +
# interpreter, run shared text-file detoxification, then audit gates.
# Operates in-place on $PBS_INSTALL.
#
# Phase 2 RPATH strategy: per-binary store-path lists.
# Each ELF gets an RPATH that lists exactly the store/<storeName>/lib
# directories that provide its DT_NEEDED bare sonames (transitive:
# libcurl's RPATH also includes openssl/zlib/nghttp2 store paths).
# $ORIGIN-relative paths keep the tree fully relocatable.

set -euo pipefail

: "${PBS_INSTALL:?}"
: "${PBS_FINALIZE_COMMON:?must be set by tree.nix}"
: "${PBS_STORE_MANIFEST:?must be set by tree.nix}"

source "$PBS_FINALIZE_COMMON"

is_elf() {
  file -b "$1" 2>/dev/null | grep -q 'ELF'
}

# ---- Build soname → storeName lookup table ----
#
# Reads PBS_STORE_MANIFEST (one "storeName nixStorePath" per line) and
# walks every *.so* file in each store path's lib/ to extract DT_SONAME.
# Result: global associative array PBS_SONAME_STORE[soname]=storeName.
#
# System sonames (glibc, libm, libpthread, …) are intentionally excluded
# — they have no store path and need no RPATH entry.

declare -A PBS_SONAME_STORE

SYSTEM_SONAMES=(
  libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1
  libresolv.so.2 libutil.so.1 "ld-linux-x86-64.so.2"
  libgcc_s.so.1 libstdc++.so.6
)

_is_system_soname() {
  local sn="$1"
  for s in "${SYSTEM_SONAMES[@]}"; do
    [ "$s" = "$sn" ] && return 0
  done
  return 1
}

_build_soname_map() {
  echo
  echo "=== finalize: building soname→storeName map ==="
  while IFS=' ' read -r storeName nixPath; do
    [ -n "$storeName" ] || continue
    [ -d "$nixPath/lib" ] || continue
    while IFS= read -r -d '' sofile; do
      [ -L "$sofile" ] && continue
      local soname
      soname="$(readelf -d "$sofile" 2>/dev/null | awk -F'[][]' '/\(SONAME\)/ {print $2}')"
      [ -n "$soname" ] || continue
      _is_system_soname "$soname" && continue
      PBS_SONAME_STORE["$soname"]="$storeName"
    done < <(find "$nixPath/lib" -name "*.so*" -print0 2>/dev/null)
  done < "$PBS_STORE_MANIFEST"

  echo "  mapped ${#PBS_SONAME_STORE[@]} bundled sonames"
  for sn in "${!PBS_SONAME_STORE[@]}"; do
    echo "    $sn → ${PBS_SONAME_STORE[$sn]}"
  done | sort
}

# ---- Compute RPATH for one ELF ----
#
# Writes to the global _RPATH_RESULT variable (colon-separated RPATH or "").
# Must NOT be called in a subshell — PBS_SONAME_STORE is an associative array
# that bash cannot export to subshells.
#
# Depth determines the number of "../" hops back to $PBS_INSTALL:
#   bin/*                    → 1 hop  ($ORIGIN/../store/<name>/lib)
#   lib/*                    → 1 hop  ($ORIGIN/../store/<name>/lib)
#   lib/extensions/<api>/*   → 3 hops ($ORIGIN/../../../store/<name>/lib)
#   store/<name>/lib/*       → 3 hops ($ORIGIN/../../../store/<Y>/lib)

_RPATH_RESULT=""

_compute_rpath() {
  local f="$1"
  _RPATH_RESULT=""

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

  # Collect unique store-path names for this ELF's DT_NEEDED.
  # seen_stores is a local associative array; we're in the main shell
  # so this is safe (no subshell needed here).
  local -A seen_stores=()
  local needed sn
  while IFS= read -r needed; do
    [ -n "$needed" ] || continue
    _is_system_soname "$needed" && continue
    sn="${PBS_SONAME_STORE[$needed]:-}"
    [ -n "$sn" ] && seen_stores["$sn"]=1
  done < <(readelf -d "$f" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ {print $2}')

  [ ${#seen_stores[@]} -eq 0 ] && return 0

  local rpath="" entry
  for sn in $(printf '%s\n' "${!seen_stores[@]}" | sort); do
    entry="\$ORIGIN/${prefix}/store/${sn}/lib"
    if [ -z "$rpath" ]; then
      rpath="$entry"
    else
      rpath="${rpath}:${entry}"
    fi
  done
  _RPATH_RESULT="$rpath"
}

# ---- Linux phases ----

linux_strip_elfs() {
  # Strip MUST run before patchelf. patchelf adds new PT_LOAD segments
  # to fit longer RPATH / interpreter strings, leaving some sections
  # (like .dynstr) "not in segment" by the time strip walks them.
  # strip-after-patchelf then warns "allocated section `.dynstr' not
  # in segment" and silently emits an ELF whose version-symbol
  # resolution is corrupt — the binary then dies at startup with
  #   "no version information available (required by .../php)"
  # Stripping first leaves the section/segment layout intact for
  # patchelf to extend cleanly.
  echo
  echo "=== finalize: strip ELFs (BEFORE patchelf) ==="
  walk_files _strip_one
}
_strip_one() {
  is_elf "$1" || return 0
  strip --strip-unneeded "$1" 2>/dev/null || true
}

linux_patchelf_walk() {
  echo
  echo "=== finalize: patchelf walk (per-binary store-path RPATHs) ==="
  patched=0
  walk_files _patchelf_one
  echo "patched $patched ELFs"
}
_patchelf_one() {
  local f="$1"
  is_elf "$f" || return 0

  # Compute RPATH in the current shell (not a subshell) so PBS_SONAME_STORE
  # associative array is accessible. _compute_rpath writes to _RPATH_RESULT.
  _RPATH_RESULT=""
  _compute_rpath "$f"
  local rpath="$_RPATH_RESULT"

  patchelf --remove-rpath "$f" 2>/dev/null || true
  if [ -n "$rpath" ]; then
    patchelf --force-rpath --set-rpath "$rpath" "$f"
  fi
  # Set interpreter on every ELF that has an INTERP segment.
  if readelf -l "$f" 2>/dev/null | grep -q INTERP; then
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$f"
  fi
  patched=$((patched + 1))
}

linux_strip_toolchain_leaks() {
  # Toolchain leaks (build host's /nix/store/<hash>-glibc/lib etc.) can
  # show up in php-config's ldflags — strip the same way we do for .pc.
  for f in "$PBS_INSTALL/bin/php-config" "$PBS_INSTALL/include/php/main/build-defs.h"; do
    [ -f "$f" ] || continue
    sed -i -E 's| -L/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/lib||g' "$f"
  done
}

linux_audit_runpath_disallowed() {
  local offenders=""
  walk_files _check_runpath
  if [ -n "$offenders" ]; then
    echo "FAIL: DT_RUNPATH found (expected DT_RPATH) in:" >&2
    echo "$offenders" >&2
    return 1
  fi
}
_check_runpath() {
  is_elf "$1" || return 0
  if readelf -d "$1" 2>/dev/null | grep -q 'RUNPATH'; then
    offenders+="$1"$'\n'
  fi
}

linux_audit_rpath_origin() {
  # Every ELF that HAS an RPATH must have $ORIGIN in it.
  # ELFs with no RPATH entry (e.g. those with zero non-system DT_NEEDED)
  # are skipped — they have nothing to resolve via RPATH.
  local nonorigin=""
  walk_files _check_rpath_origin
  if [ -n "$nonorigin" ]; then
    echo "FAIL: non-\$ORIGIN RPATH in:" >&2
    echo "$nonorigin" >&2
    return 1
  fi
}
_check_rpath_origin() {
  is_elf "$1" || return 0
  local rp
  rp="$(readelf -d "$1" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)"
  if [ -n "$rp" ] && ! echo "$rp" | grep -q '\$ORIGIN'; then
    nonorigin+="$1: $rp"$'\n'
  fi
}

linux_audit_needed_bare() {
  # DT_NEEDED entries must be bare sonames, never absolute paths.
  local bad=""
  walk_files _check_needed_bare
  if [ -n "$bad" ]; then
    echo "FAIL: DT_NEEDED with absolute path (must be bare soname):" >&2
    echo "$bad" >&2
    return 1
  fi
}
_check_needed_bare() {
  is_elf "$1" || return 0
  while IFS= read -r needed; do
    case "$needed" in
      */*) bad+="$1: NEEDED [$needed]"$'\n' ;;
    esac
  done < <(readelf -d "$1" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ {print $2}')
}

linux_audit_interp() {
  local bad=""
  walk_files _check_interp
  if [ -n "$bad" ]; then
    echo "FAIL: wrong interpreter in:" >&2
    echo "$bad" >&2
    return 1
  fi
}
_check_interp() {
  if readelf -l "$1" 2>/dev/null | grep -q INTERP; then
    local interp
    interp="$(readelf -p .interp "$1" 2>/dev/null | awk '/\[/{print $NF}' | head -1)"
    if [ "$interp" != "/lib64/ld-linux-x86-64.so.2" ]; then
      bad+="$1: $interp"$'\n'
    fi
  fi
}

linux_audit_rpath_resolves() {
  # For every ELF, simulate ld.so resolution: for each non-system DT_NEEDED
  # soname, confirm the encoded RPATH contains an entry that actually
  # provides that soname (file present in the resolved directory).
  # This catches the "RPATH set but points at wrong store path" class of bug.
  local fail=""
  walk_files _check_rpath_resolves
  if [ -n "$fail" ]; then
    echo "FAIL: DT_NEEDED soname not found via RPATH:" >&2
    echo "$fail" >&2
    return 1
  fi
}
_check_rpath_resolves() {
  local f="$1"
  is_elf "$f" || return 0

  local dir
  dir="$(dirname "$f")"

  # Get all DT_NEEDED sonames, skip system ones.
  local neededs=()
  while IFS= read -r needed; do
    [ -n "$needed" ] || continue
    _is_system_soname "$needed" && continue
    # Also skip PHP extension sonames (they don't appear in DT_NEEDED of
    # other ELFs, but extension .so itself may DT_NEEDED its own soname
    # which would be in its own dir — handled by self-rpath already).
    neededs+=("$needed")
  done < <(readelf -d "$f" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ {print $2}')

  [ ${#neededs[@]} -eq 0 ] && return 0

  # Read RPATH entries, resolve $ORIGIN against the file's directory.
  local rpath_entries=()
  local raw_rpath
  raw_rpath="$(readelf -d "$f" 2>/dev/null | awk -F'[][]' '/\(RPATH\)/ {print $2}')"
  if [ -z "$raw_rpath" ]; then
    # ELF has non-system DT_NEEDEDs but no RPATH — only OK if all those
    # sonames are themselves bundled deps the ELF is INSIDE (shouldn't
    # happen per our layout). Flag it.
    if [ ${#neededs[@]} -gt 0 ]; then
      fail+="$f: has non-system DT_NEEDED but no RPATH: ${neededs[*]}"$'\n'
    fi
    return 0
  fi
  IFS=':' read -ra rpath_entries <<< "$raw_rpath"

  # Resolve $ORIGIN
  local resolved_dirs=()
  for entry in "${rpath_entries[@]}"; do
    local resolved="${entry/\$ORIGIN/$dir}"
    resolved_dirs+=("$resolved")
  done

  # Check each non-system DT_NEEDED
  for needed in "${neededs[@]}"; do
    local found=0
    for rdir in "${resolved_dirs[@]}"; do
      if [ -e "$rdir/$needed" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      fail+="$f: cannot resolve $needed via RPATH ($raw_rpath)"$'\n'
    fi
  done
}

# ---- Phase dispatch ----

_build_soname_map

run_phases \
  linux_strip_elfs \
  linux_patchelf_walk \
  common_remove_la_files \
  common_detoxify_pc_files \
  common_detoxify_text_files \
  common_rewrite_phpize_prefix \
  linux_strip_toolchain_leaks \
  common_audit_no_nix_store_text \
  linux_audit_runpath_disallowed \
  linux_audit_rpath_origin \
  linux_audit_needed_bare \
  linux_audit_interp \
  linux_audit_rpath_resolves
