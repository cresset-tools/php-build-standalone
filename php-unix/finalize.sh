#!/usr/bin/env bash
# Finalize the staging tree — convert it from a Nix-built directory to a
# truly portable tarball root. Operates in-place on $PBS_INSTALL, which
# the caller (the tree.nix derivation) has already populated by merging
# every per-dep derivation's lib/, include/, etc. into a single tree.
# Steps:
#   1. patchelf every ELF: remove any rpath, force DT_RPATH=$ORIGIN/../lib,
#      set interpreter to /lib64/ld-linux-x86-64.so.2 (system path).
#   2. Delete libtool .la files (build-time path leaks).
#   3. Strip binaries.
#   4. Run audit gates from plan §2 — fail loudly if any leak slipped.

set -euo pipefail

: "${PBS_INSTALL:?}"

echo
echo "=== finalize: strip ELFs (BEFORE patchelf) ==="
# Strip MUST run before patchelf. patchelf adds new PT_LOAD segments to
# fit longer RPATH / interpreter strings, leaving some sections (like
# .dynstr) "not in segment" by the time strip walks them. strip-after-
# patchelf then warns "allocated section `.dynstr' not in segment" and
# silently emits an ELF whose version-symbol resolution is corrupt —
# the binary then dies at startup with
#   "no version information available (required by .../php)"
# and a long string of similar errors. Stripping first leaves the
# section/segment layout intact for patchelf to extend cleanly.
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  if file -b "$f" 2>/dev/null | grep -q 'ELF'; then
    strip --strip-unneeded "$f" 2>/dev/null || true
  fi
done < <(find "$PBS_INSTALL" -type f -print0)

echo
echo "=== finalize: patchelf walk ==="
# Walk every regular file under install/ and patchelf the ELFs.
# Use 'file' to detect ELF rather than relying on extension — extension
# .so files exist (from PHP) but so do binaries with no extension (php, php-fpm).
patched=0
while IFS= read -r -d '' f; do
  # Skip symlinks; we patch the resolved target only.
  [ -L "$f" ] && continue
  if ! file -b "$f" 2>/dev/null | grep -q 'ELF'; then
    continue
  fi
  patchelf --remove-rpath "$f" 2>/dev/null || true
  patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$f"
  # Set interpreter on every ELF that has an INTERP segment. We check
  # that via readelf rather than `file` output — `file` reports
  # PIE-executables as "pie executable, ... dynamically linked" (order
  # varies by file version) so a single regex doesn't catch both
  # PIE and non-PIE executables. .so files have no INTERP segment, so
  # readelf -l prints nothing for INTERP and we correctly skip them.
  if readelf -l "$f" 2>/dev/null | grep -q INTERP; then
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$f"
  fi
  patched=$((patched + 1))
done < <(find "$PBS_INSTALL" -type f -print0)
echo "patched $patched ELFs"

# Step 3: delete .la files (libtool archives — they bake in build-time
# absolute paths that downstream extension builds choke on).
echo
echo "=== finalize: removing .la files ==="
find "$PBS_INSTALL" -name '*.la' -print -delete

# Step 3b: rewrite absolute build-time paths in .pc / .pc-like text files.
# Each per-dep derivation embeds its own /nix/store/<hash>-pbs-<name>-<ver>
# prefix into pkg-config files; downstream consumers (phpize, php-config,
# pecl install) read those at install time so we MUST detoxify before
# tarball. ${pcfiledir} is a pkg-config builtin (since 0.27) that expands
# to the directory containing the .pc at query time, so a relative
# prefix works no matter where the tarball is extracted.
#
# This walks every .pc and replaces literal store paths with
# ${pcfiledir}/../.. (one step out of pkgconfig/, one step out of lib/,
# leaving the install prefix). Same pattern PBS uses for sysconfig data.
echo
echo "=== finalize: detoxifying .pc files ==="
while IFS= read -r -d '' pc; do
  # Two classes of /nix/store path can leak into .pc files:
  #
  # (1) Our own pbs-<dep> install prefixes (the build-time location of the
  #     dep being described by this .pc, or sibling deps it depends on).
  #     Replace with ${pcfiledir}/../.. — a pkg-config builtin that
  #     resolves to the .pc file's parent directory at query time, so it
  #     survives relocation.
  sed -i -E 's|/nix/store/[a-z0-9]{32}-pbs-[^/[:space:]"]*|${pcfiledir}/../..|g' "$pc"
  #
  # (2) Toolchain paths (-L/nix/store/<hash>-glibc/lib, -L/nix/store/<hash>-gcc-13.3.0-lib/lib)
  #     that landed in Libs.private from our LDFLAGS during configure.
  #     These point at the build host's glibc/libgcc, which won't exist on
  #     consumer machines. Strip them entirely — the consumer's system
  #     glibc + libgcc live at /lib64 / /usr/lib (system search paths) so
  #     pkg-config consumers don't need explicit -L flags for them.
  sed -i -E 's| -L/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/lib||g' "$pc"
  echo "  rewrote $pc"
done < <(find "$PBS_INSTALL" -name '*.pc' -print0)

# Step 3c: global text-file detoxify. PHP's install bakes its build-time
# install prefix (and dep prefixes) into many text files: bin/phpize,
# bin/php-config, include/php/main/build-defs.h (PHP_PREFIX et al),
# etc/php-fpm.conf.default, lib/php/build/Makefile.global, ...
#
# Strategy: replace every /nix/store/<hash>-pbs-<dep>-<ver> prefix with a
# placeholder /__PBS_PREFIX__. The audit then passes (no /nix/store left)
# and consumers see an obvious sentinel rather than a path that points
# nowhere. PHP's runtime defaults (extension_dir etc.) will be wrong;
# users override via php.ini. For phpize/php-config (which compute
# $prefix from $0 at runtime), we then convert the sentinel into a $prefix
# expansion so they Just Work.
echo
echo "=== finalize: detoxifying installed text files ==="

# .conf.default files are templates for php-fpm — they bake build-time
# paths in comments AND in the load-bearing `include=` directive. Drop
# them entirely: users author their own config, and shipping a broken
# template is worse than shipping no template.
rm -f "$PBS_INSTALL/etc/php-fpm.conf.default"
rm -rf "$PBS_INSTALL/etc/php-fpm.d"

# Walk every text file once, sed-replace pbs-* store paths with sentinel.
# Use grep -lI (text only, recursive) to find candidates.
mapfile -t text_files < <(grep -rIl '/nix/store/[a-z0-9]\{32\}-pbs-' "$PBS_INSTALL" 2>/dev/null || true)
for f in "${text_files[@]}"; do
  sed -i -E 's|/nix/store/[a-z0-9]{32}-pbs-[^/[:space:]"'"'"']*|/__PBS_PREFIX__|g' "$f"
  echo "  detoxified $f"
done

# Toolchain leaks (build host's /nix/store/<hash>-glibc/lib etc.) can show
# up in php-config's ldflags — strip the same way we do for .pc files.
for f in "$PBS_INSTALL/bin/php-config" "$PBS_INSTALL/include/php/main/build-defs.h"; do
  [ -f "$f" ] || continue
  sed -i -E 's| -L/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/lib||g' "$f"
done

# Phpize and php-config have $prefix already computed from $0 (we patched
# scripts/phpize.in and scripts/php-config.in pre-configure). Convert the
# sentinel back into a $prefix shell expansion so their internal paths
# track the actual install location at runtime.
for f in "$PBS_INSTALL/bin/phpize" "$PBS_INSTALL/bin/php-config"; do
  [ -f "$f" ] || continue
  # /__PBS_PREFIX__ → $prefix. Use # delimiter; replacement contains no #.
  sed -i 's#/__PBS_PREFIX__#$prefix#g' "$f"
done

# (strip already done at the top of finalize, before patchelf — see
# the rationale comment up there. Re-stripping here would re-trigger
# the same patchelf-output corruption.)

# Step 5: audit gates from plan §2.
echo
echo "=== finalize: audit gates ==="

fail=0

# Gate A: no /nix/store references in TEXT files. We deliberately skip
# binary files (`grep -I` excludes them) — some build systems bake
# build-time paths into ELF rodata as diagnostic strings ("compiler:"
# version line in libcrypto) or runtime plugin lookup paths (ENGINESDIR,
# MODULESDIR). They're inert: the /nix/store paths don't exist on
# consumer machines, so any code that consults them silently fails,
# and we don't ship the corresponding engine/provider .so files anyway.
# What we DO care about is text-file leaks — .pc, .la, helper scripts,
# Makefile.global etc. — which are read by downstream tooling
# (php-config, pecl, phpize) at install time on the consumer side.
nix_residue="$(grep -rIl '/nix/store' "$PBS_INSTALL" 2>/dev/null || true)"
if [ -n "$nix_residue" ]; then
  echo "FAIL: /nix/store paths found in text files:" >&2
  echo "$nix_residue" >&2
  fail=1
fi

# Gate B: no DT_RUNPATH in any ELF (we want DT_RPATH only).
runpath_offenders=""
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  if file -b "$f" 2>/dev/null | grep -q 'ELF'; then
    if readelf -d "$f" 2>/dev/null | grep -q 'RUNPATH'; then
      runpath_offenders+="$f"$'\n'
    fi
  fi
done < <(find "$PBS_INSTALL" -type f -print0)
if [ -n "$runpath_offenders" ]; then
  echo "FAIL: DT_RUNPATH found (expected DT_RPATH) in:" >&2
  echo "$runpath_offenders" >&2
  fail=1
fi

# Gate C: every ELF has $ORIGIN-relative RPATH (or none, but that's stricter).
nonorigin=""
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  if file -b "$f" 2>/dev/null | grep -q 'ELF'; then
    rp="$(readelf -d "$f" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)"
    if [ -n "$rp" ] && ! echo "$rp" | grep -q '\$ORIGIN'; then
      nonorigin+="$f: $rp"$'\n'
    fi
  fi
done < <(find "$PBS_INSTALL" -type f -print0)
if [ -n "$nonorigin" ]; then
  echo "FAIL: non-\$ORIGIN RPATH in:" >&2
  echo "$nonorigin" >&2
  fail=1
fi

# Gate D-pre: DT_NEEDED entries must be bare sonames, never absolute paths.
# A /nix/store/...-libfoo.so in DT_NEEDED is the load-bearing failure mode
# we couldn't detect by skipping binaries in Gate A: at runtime the dynamic
# linker honors absolute DT_NEEDED literally, and the consumer machine has
# no /nix/store/, so the lib fails to load and PHP fails to start. Bare
# sonames (libfoo.so.N) are required so the loader resolves via our
# DT_RPATH=$ORIGIN/../lib (Gate C) plus the system loader cache for libc/etc.
bad_needed=""
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  if file -b "$f" 2>/dev/null | grep -q 'ELF'; then
    # readelf format: " 0x...0001 (NEEDED)  Shared library: [<value>]"
    while IFS= read -r needed; do
      case "$needed" in
        */*)
          bad_needed+="$f: NEEDED [$needed]"$'\n'
          ;;
      esac
    done < <(readelf -d "$f" 2>/dev/null \
              | awk -F'[][]' '/\(NEEDED\)/ {print $2}')
  fi
done < <(find "$PBS_INSTALL" -type f -print0)
if [ -n "$bad_needed" ]; then
  echo "FAIL: DT_NEEDED with absolute path (must be bare soname):" >&2
  echo "$bad_needed" >&2
  fail=1
fi

# Gate D: every executable with an INTERP segment points at
# /lib64/ld-linux-x86-64.so.2. Same INTERP-detection trick as the
# patchelf walk above (PIE-vs-non-PIE confuses `file` regexes).
bad_interp=""
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  if readelf -l "$f" 2>/dev/null | grep -q INTERP; then
    interp="$(readelf -p .interp "$f" 2>/dev/null | awk '/\[/{print $NF}' | head -1)"
    if [ "$interp" != "/lib64/ld-linux-x86-64.so.2" ]; then
      bad_interp+="$f: $interp"$'\n'
    fi
  fi
done < <(find "$PBS_INSTALL" -type f -print0)
if [ -n "$bad_interp" ]; then
  echo "FAIL: wrong interpreter in:" >&2
  echo "$bad_interp" >&2
  fail=1
fi

if [ $fail -ne 0 ]; then
  echo >&2
  echo "finalize audit FAILED" >&2
  exit 1
fi

echo "all audit gates passed"
echo "install root: $PBS_INSTALL"
