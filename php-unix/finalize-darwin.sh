#!/usr/bin/env bash
# Finalize a Darwin staging tree: rewrite install names + LC_LOAD_DYLIB
# entries to be relocatable, add @loader_path/.. rpaths, run shared
# text-file detoxification, ad-hoc codesign, then audit. Operates
# in-place on $PBS_INSTALL.
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

  # 2. Rewrite every LC_LOAD_DYLIB that isn't already portable to
  #    @rpath/<basename>. Three classes of non-portable load command:
  #      a. /nix/store/...-pbs-* — build-time absolute path.
  #      b. unqualified bare filename like `libicuuc.75.dylib` — emitted
  #         by ICU's autotools build and our hand-rolled bzip2. dyld
  #         looks these up in DYLD_FALLBACK_*, not at @rpath, so they
  #         would fail to load on the consumer.
  #    Skip system libs (/usr/lib/*, /System/*) and already-rewritten
  #    @rpath/@loader_path/@executable_path entries.
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
        # Bare filename. install_name_tool's -change needs the EXACT
        # current value, which is the unqualified name.
        "$INSTALL_NAME_TOOL" -change "$dep" "@rpath/$dep" "$f"
        ;;
    esac
  done < <("$OTOOL" -L "$f" 2>/dev/null | awk 'NR>1 {print $1}')

  # 3. Add LC_RPATH = @loader_path/../lib (for bin/* loading lib/*) and
  #    @loader_path (for lib/* loading sibling lib/*). Strip any other
  #    LC_RPATH that snuck in from the build host.
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    case "$rp" in
      "@loader_path/../lib"|"@loader_path") ;;
      *) "$INSTALL_NAME_TOOL" -delete_rpath "$rp" "$f" 2>/dev/null || true ;;
    esac
  done < <("$OTOOL" -l "$f" 2>/dev/null \
            | awk '/cmd LC_RPATH/{flag=1; next} flag && /path /{print $2; flag=0}')

  "$INSTALL_NAME_TOOL" -add_rpath "@loader_path/../lib" "$f" 2>/dev/null || true
  "$INSTALL_NAME_TOOL" -add_rpath "@loader_path"        "$f" 2>/dev/null || true

  patched=$((patched + 1))
}

darwin_strip_toolchain_leaks() {
  # PHP records its configure invocation in bin/php-config (CFLAGS/
  # CPPFLAGS/LDFLAGS lines) and in include/php/main/build-defs.h
  # (CONFIGURE_COMMAND macro). Both reference build-time include/lib
  # paths of every dep in nativeBuildInputs that we passed via
  # -isystem / -L flags — including darwin.libresolv which we need for
  # headers but don't ship as part of the tarball. Strip them.
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
  # strip -x removes non-global symbols (smaller). install_name_tool
  # already ran above; codesign runs after this, so the strip-induced
  # signature invalidation is OK.
  walk_files _darwin_strip_one
}
_darwin_strip_one() {
  is_macho "$1" || return 0
  strip -x "$1" 2>/dev/null || true
}

darwin_codesign() {
  echo
  echo "=== finalize: ad-hoc codesign ==="
  # --force overwrites any existing (now-invalid) signature.
  # --sign - is the literal dash, meaning ad-hoc (no identity, no keys).
  # --preserve-metadata=entitlements,requirements,flags keeps the
  # linker-emitted entitlement set if any.
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
  # Every Mach-O's LC_RPATH set is a subset of the allowlist
  # (@loader_path/../lib, @loader_path). No build-host paths.
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
      "@loader_path/../lib"|"@loader_path") ;;
      *) bad+="$1: $rp"$'\n' ;;
    esac
  done < <("$OTOOL" -l "$1" 2>/dev/null \
            | awk '/cmd LC_RPATH/{flag=1; next} flag && /path /{print $2; flag=0}')
}

darwin_audit_load_dylib() {
  # Every LC_LOAD_DYLIB is @rpath/..., /usr/lib/..., or /System/... —
  # never an absolute build-host path.
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
