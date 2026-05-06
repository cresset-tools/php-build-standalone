#!/usr/bin/env bash
# Finalize the staging tree on Linux: strip ELFs, patchelf RPATH +
# interpreter, run shared text-file detoxification, then audit gates.
# Operates in-place on $PBS_INSTALL.

set -euo pipefail

: "${PBS_INSTALL:?}"
: "${PBS_FINALIZE_COMMON:?must be set by tree.nix}"

source "$PBS_FINALIZE_COMMON"

is_elf() {
  file -b "$1" 2>/dev/null | grep -q 'ELF'
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
  echo "=== finalize: patchelf walk ==="
  patched=0
  walk_files _patchelf_one
  echo "patched $patched ELFs"
}
_patchelf_one() {
  local f="$1"
  is_elf "$f" || return 0
  patchelf --remove-rpath "$f" 2>/dev/null || true
  patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$f"
  # Set interpreter on every ELF that has an INTERP segment. We check
  # via readelf rather than `file` — `file` reports PIE-executables as
  # "pie executable, ... dynamically linked" (order varies by file
  # version). .so files have no INTERP segment, so readelf -l prints
  # nothing for INTERP and we correctly skip them.
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
  # DT_NEEDED entries must be bare sonames, never absolute paths. A
  # /nix/store/...-libfoo.so in DT_NEEDED is the load-bearing failure
  # mode the text-file gate can't catch: at runtime the dynamic linker
  # honors absolute DT_NEEDED literally, and consumers have no
  # /nix/store/, so the lib fails to load and PHP fails to start. Bare
  # sonames (libfoo.so.N) are required so the loader resolves via our
  # DT_RPATH=$ORIGIN/../lib (gate C) plus the system loader cache.
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

# ---- Phase dispatch ----

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
  linux_audit_interp
