#!/usr/bin/env bash
# Finalize a Darwin staging tree: rewrite install names + LC_LOAD_DYLIB
# entries to be relocatable, add @loader_path/.. rpaths, ad-hoc codesign,
# and audit. Operates in-place on $PBS_INSTALL.
#
# Why ad-hoc codesign at the end:
#   On aarch64 macOS the linker auto-emits an ad-hoc signature on every
#   Mach-O. install_name_tool mutations invalidate that signature, after
#   which AMFI / syspolicyd refuses to load the binary on Sequoia+, and
#   the user sees a SIGKILL with no explanation. PBS hits this bug;
#   uv hits it; PR #17123 to add post-install codesigning to uv was
#   closed unmerged. We do it here at build time so the artifact ships
#   pre-validated. Ad-hoc signing requires no Apple Developer account,
#   no keys, no network — just /usr/bin/codesign --sign -.
#
# Order matters: install_name_tool walk → strip → codesign. Stripping
# also invalidates signatures, so codesign MUST come last.

set -euo pipefail

: "${PBS_INSTALL:?}"

# Tools: codesign + install_name_tool + otool live in /usr/bin on every
# macOS install (CommandLineTools or full Xcode). Use absolute paths so
# we don't depend on a sandboxed PATH ordering.
INSTALL_NAME_TOOL=/usr/bin/install_name_tool
OTOOL=/usr/bin/otool
CODESIGN=/usr/bin/codesign

is_macho() {
  # `file -b` on Darwin reports "Mach-O 64-bit dynamically linked shared
  # library arm64" or "Mach-O 64-bit executable arm64". Grep for the
  # leading "Mach-O" token.
  file -b "$1" 2>/dev/null | grep -q '^Mach-O'
}

# Returns 0 if the file is a Mach-O dylib (vs. an executable / bundle).
is_dylib() {
  file -b "$1" 2>/dev/null | grep -q 'Mach-O.* dynamically linked shared library'
}

echo
echo "=== finalize-darwin: install_name_tool walk ==="
patched=0
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  is_macho "$f" || continue

  # 1. For dylibs: rewrite LC_ID_DYLIB to @rpath/<basename>. Consumers
  #    loading us via DT_NEEDED-equivalent will resolve the @rpath against
  #    the loading binary's LC_RPATH (which we set below).
  if is_dylib "$f"; then
    base="$(basename "$f")"
    "$INSTALL_NAME_TOOL" -id "@rpath/$base" "$f"
  fi

  # 2. Rewrite every LC_LOAD_DYLIB that isn't already portable to
  #    @rpath/<basename>. Three classes of non-portable load command:
  #      a. /nix/store/...-pbs-* — build-time absolute path.
  #      b. unqualified bare filename like `libicuuc.75.dylib` — emitted
  #         by ICU's autotools build (it sets -install_name to the
  #         basename) and by the bzip2 hand-rolled link command. dyld
  #         treats these as install_names to look up in DYLD_FALLBACK_*,
  #         not at @rpath, so they would fail to load on the consumer.
  #         Rewrite to @rpath/<name> so our LC_RPATH catches them.
  #    Skip system libs (/usr/lib/*, /System/*) and already-rewritten
  #    @rpath/@loader_path/@executable_path entries — those are fine.
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      "/usr/lib/"*|"/System/"*|"@rpath/"*|"@loader_path/"*|"@executable_path/"*)
        ;;
      /*)
        # Any other absolute path (covers /nix/store/...-pbs-*).
        depbase="$(basename "$dep")"
        "$INSTALL_NAME_TOOL" -change "$dep" "@rpath/$depbase" "$f"
        ;;
      */*)
        # Relative path with slashes — also non-portable, rewrite.
        depbase="$(basename "$dep")"
        "$INSTALL_NAME_TOOL" -change "$dep" "@rpath/$depbase" "$f"
        ;;
      *)
        # Bare filename (no slashes). install_name_tool's -change needs
        # the EXACT current value, which is the unqualified name.
        "$INSTALL_NAME_TOOL" -change "$dep" "@rpath/$dep" "$f"
        ;;
    esac
  done < <("$OTOOL" -L "$f" 2>/dev/null | awk 'NR>1 {print $1}')

  # 3. Add LC_RPATH = @loader_path/../lib (for bin/* loading lib/*) and
  #    @loader_path (for lib/* loading sibling lib/*). Strip any other
  #    LC_RPATH that snuck in from the build host. install_name_tool's
  #    -delete_rpath needs the exact value, so enumerate first.
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    case "$rp" in
      "@loader_path/../lib"|"@loader_path") continue ;;
      *) "$INSTALL_NAME_TOOL" -delete_rpath "$rp" "$f" 2>/dev/null || true ;;
    esac
  done < <("$OTOOL" -l "$f" 2>/dev/null \
            | awk '/cmd LC_RPATH/{flag=1; next} flag && /path /{print $2; flag=0}')

  # Idempotently add the two we want. install_name_tool errors if the
  # rpath already exists; suppress that.
  "$INSTALL_NAME_TOOL" -add_rpath "@loader_path/../lib" "$f" 2>/dev/null || true
  "$INSTALL_NAME_TOOL" -add_rpath "@loader_path"        "$f" 2>/dev/null || true

  patched=$((patched + 1))
done < <(find "$PBS_INSTALL" -type f -print0)
echo "patched $patched Mach-Os"

echo
echo "=== finalize-darwin: removing .la files ==="
find "$PBS_INSTALL" -name '*.la' -print -delete

echo
echo "=== finalize-darwin: detoxifying .pc files ==="
while IFS= read -r -d '' pc; do
  # GNU sed syntax — gnused is provided as a build input. Same form as
  # the Linux finalize.sh; BSD sed's `-i ''` is NOT used here.
  sed -i -E 's|/nix/store/[a-z0-9]{32}-pbs-[^/[:space:]"]*|${pcfiledir}/../..|g' "$pc"
  sed -i -E 's| -L/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/lib||g' "$pc"
  echo "  rewrote $pc"
done < <(find "$PBS_INSTALL" -name '*.pc' -print0)

echo
echo "=== finalize-darwin: detoxifying installed text files ==="
# .conf.default templates bake build-time paths in load-bearing
# `include=` directives. Drop them entirely; users author their own.
rm -f "$PBS_INSTALL/etc/php/php-fpm.conf.default"
rm -rf "$PBS_INSTALL/etc/php/php-fpm.d"

# Replace every pbs-<dep>-<ver> store-prefix occurrence in text files
# with a /__PBS_PREFIX__ sentinel. phpize/php-config compute $prefix
# from $0 at runtime; we re-substitute the sentinel back to $prefix
# below so they keep working post-relocation.
mapfile -t text_files < <(grep -rIl '/nix/store/[a-z0-9]\{32\}-pbs-' "$PBS_INSTALL" 2>/dev/null || true)
for f in "${text_files[@]}"; do
  sed -i -E 's|/nix/store/[a-z0-9]{32}-pbs-[^/[:space:]"'"'"']*|/__PBS_PREFIX__|g' "$f"
  echo "  detoxified $f"
done

# Toolchain / build-input leaks. PHP records its configure invocation in
# bin/php-config (CFLAGS/CPPFLAGS/LDFLAGS lines) and in
# include/php/main/build-defs.h (CONFIGURE_COMMAND macro). Both reference
# the build-time include/lib paths of every dep in nativeBuildInputs that
# we passed via -isystem / -L flags — including darwin.libresolv which we
# need for headers but don't ship as part of the tarball. Strip them.
for f in "$PBS_INSTALL/bin/php-config" "$PBS_INSTALL/include/php/main/build-defs.h"; do
  [ -f "$f" ] || continue
  sed -i -E 's| -L/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/lib||g' "$f"
  sed -i -E 's| -isystem +/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/include||g' "$f"
  sed -i -E 's|-isystem +/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/include||g' "$f"
done

# phpize / php-config: convert sentinel back to a $prefix shell expansion
# so their internal paths track the actual install location at runtime.
# (scripts/phpize.in / scripts/php-config.in were patched pre-configure
# to compute $prefix from $0.)
for f in "$PBS_INSTALL/bin/phpize" "$PBS_INSTALL/bin/php-config"; do
  [ -f "$f" ] || continue
  sed -i 's#/__PBS_PREFIX__#$prefix#g' "$f"
done

echo
echo "=== finalize-darwin: strip Mach-Os ==="
# strip on Darwin without args strips debug symbols; -x removes non-global
# symbols too (smaller). install_name_tool already ran above; codesign
# will run after this, so the strip-induced signature invalidation is OK.
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  is_macho "$f" || continue
  strip -x "$f" 2>/dev/null || true
done < <(find "$PBS_INSTALL" -type f -print0)

echo
echo "=== finalize-darwin: ad-hoc codesign ==="
# --force overwrites any existing (now-invalid) signature.
# --sign - is the literal dash, meaning ad-hoc (no identity, no keys).
# --preserve-metadata=entitlements,requirements,flags keeps the linker-
# emitted entitlement set if any.
signed=0
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  is_macho "$f" || continue
  "$CODESIGN" --force --sign - --preserve-metadata=entitlements,requirements,flags "$f"
  signed=$((signed + 1))
done < <(find "$PBS_INSTALL" -type f -print0)
echo "signed $signed Mach-Os"

echo
echo "=== finalize-darwin: audit gates ==="
fail=0

# Gate A: no /nix/store residue in text files.
nix_residue="$(grep -rIl '/nix/store' "$PBS_INSTALL" 2>/dev/null || true)"
if [ -n "$nix_residue" ]; then
  echo "FAIL: /nix/store paths found in text files:" >&2
  echo "$nix_residue" >&2
  fail=1
fi

# Gate C-darwin: every Mach-O's LC_RPATH set is a subset of the allowlist
# (@loader_path/../lib, @loader_path). No build-host paths.
bad_rpath=""
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  is_macho "$f" || continue
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    case "$rp" in
      "@loader_path/../lib"|"@loader_path") ;;
      *) bad_rpath+="$f: $rp"$'\n' ;;
    esac
  done < <("$OTOOL" -l "$f" 2>/dev/null \
            | awk '/cmd LC_RPATH/{flag=1; next} flag && /path /{print $2; flag=0}')
done < <(find "$PBS_INSTALL" -type f -print0)
if [ -n "$bad_rpath" ]; then
  echo "FAIL: non-allowlisted LC_RPATH:" >&2
  echo "$bad_rpath" >&2
  fail=1
fi

# Gate D-pre-darwin: every LC_LOAD_DYLIB is @rpath/..., /usr/lib/..., or
# /System/... — never an absolute build-host path.
bad_load=""
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  is_macho "$f" || continue
  while IFS= read -r dep; do
    case "$dep" in
      "@rpath/"*|"/usr/lib/"*|"/System/"*|"@loader_path/"*|"@executable_path/"*) ;;
      "") ;;
      *) bad_load+="$f: LC_LOAD_DYLIB $dep"$'\n' ;;
    esac
  done < <("$OTOOL" -L "$f" 2>/dev/null | awk 'NR>1 {print $1}')
done < <(find "$PBS_INSTALL" -type f -print0)
if [ -n "$bad_load" ]; then
  echo "FAIL: non-portable LC_LOAD_DYLIB:" >&2
  echo "$bad_load" >&2
  fail=1
fi

# Gate E-darwin: every Mach-O has a valid (ad-hoc) signature.
bad_sig=""
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  is_macho "$f" || continue
  if ! "$CODESIGN" --verify --strict "$f" 2>/dev/null; then
    bad_sig+="$f"$'\n'
  fi
done < <(find "$PBS_INSTALL" -type f -print0)
if [ -n "$bad_sig" ]; then
  echo "FAIL: invalid or missing codesign:" >&2
  echo "$bad_sig" >&2
  fail=1
fi

if [ $fail -ne 0 ]; then
  echo >&2
  echo "finalize-darwin audit FAILED" >&2
  exit 1
fi

echo "all audit gates passed"
echo "install root: $PBS_INSTALL"
