#!/usr/bin/env bash
# prepare-php.sh — patch PHP source files BEFORE configure runs.
#
# The headline patches: rewrite scripts/phpize.in and scripts/php-config.in
# so the prefix is computed at runtime from $0 instead of being hardcoded
# to the build-time install path. Without these, every relocated tarball
# is broken — `pecl install <ext>` against the moved tarball fails because
# phpize emits the wrong include / build-files path.
#
# Patch dispatch: the patches/ directory holds files named
#
#     NNNN-<short-name>@LO-HI.patch
#
# where NNNN is a sequence number (controls apply order), and LO/HI are
# inclusive PHP version bounds in major-minor form with no dot — i.e. 81
# means "PHP 8.1" and 99 means "effective infinity, applies to all future
# versions". So 0002-relocate-php-config@84-99.patch applies to PHP 8.4
# onward, and 0002-relocate-php-config@81-83.patch covers the older shape.
#
# To add a patch for a single new version, drop in a file with the
# appropriate range — the dispatch below picks it up automatically. To
# split a patch when upstream changes context lines (as happened when 8.4
# added `lib_dir` to scripts/php-config.in, and again when 8.5 changed the
# `php --ini` printf format), narrow the existing patch's range and add a
# new file covering the newer range. No script edits required.
#
# Invariant: at most one patch per NNNN may apply to a given PHP version.
# If two ranges overlap, this script fails loudly — that's an authoring
# error, not something to silently resolve.
#
# Inputs: cwd is the unpacked PHP source tree.
#         PBS_VER_PHP_MAJORMINOR is exported by mkDep.nix from phpSpec
#         (e.g. "8.1.31" → "8.1"). Load-bearing.
#         PBS_PHP_PATCHES_DIR points at the patches/ directory.

set -euo pipefail

if [ ! -f scripts/phpize.in ] || [ ! -f scripts/php-config.in ]; then
  echo "prepare-php.sh: must be run from the unpacked PHP source tree" >&2
  exit 1
fi

: "${PBS_VER_PHP_MAJORMINOR:?prepare-php.sh: PBS_VER_PHP_MAJORMINOR must be set}"
: "${PBS_PHP_PATCHES_DIR:?prepare-php.sh: PBS_PHP_PATCHES_DIR must be set}"

# Convert "8.5" → 85 for integer range comparisons. PHP's CalVer doesn't
# go above single digits per component within the windows we ship, so a
# simple "drop the dot" works; if PHP ever ships 8.10, we'd revisit.
ver_num="${PBS_VER_PHP_MAJORMINOR//./}"
case "$ver_num" in
  ''|*[!0-9]*)
    echo "prepare-php.sh: PBS_VER_PHP_MAJORMINOR='$PBS_VER_PHP_MAJORMINOR' did not yield a numeric version" >&2
    exit 1
    ;;
esac

echo "=== prepare-php: dispatching patches for PHP $PBS_VER_PHP_MAJORMINOR (numeric: $ver_num) ==="

# --fuzz=2 absorbs line-offset drift in the larger C-source patches
# (php_ini.c, main.c, fpm_conf.c) across PHP minors without needing a
# per-version patch per touched file. If a touched anchor ever moves
# further, patch will fail loudly here rather than producing a silently-
# broken build. Increase only as a last resort — fuzzy matches are quiet
# bugs waiting to happen.
PATCH_OPTS="--fuzz=2 -p1"

# Pass 1: enumerate all patches, parse the @LO-HI suffix, filter by range,
# detect collisions (two patches with same NNNN both matching this version).
declare -A group_seen          # NNNN -> selected basename
declare -a selected_files      # ordered list of full paths to apply

# Sort with LC_ALL=C so the leading-NNNN ordering is stable.
mapfile -t all_patches < <(LC_ALL=C ls -1 "$PBS_PHP_PATCHES_DIR"/*.patch 2>/dev/null)
if [ ${#all_patches[@]} -eq 0 ]; then
  echo "prepare-php.sh: no *.patch files found in $PBS_PHP_PATCHES_DIR" >&2
  exit 1
fi

for patch_file in "${all_patches[@]}"; do
  bn=$(basename "$patch_file")
  # Reject any patch that doesn't conform to the naming convention — that
  # would silently bypass dispatch and either be applied for every version
  # or for none, both surprising.
  if [[ ! "$bn" =~ ^([0-9]+)-.*@([0-9]+)-([0-9]+)\.patch$ ]]; then
    echo "prepare-php.sh: patch '$bn' violates NNNN-name@LO-HI.patch naming" >&2
    exit 1
  fi
  group="${BASH_REMATCH[1]}"
  lo="${BASH_REMATCH[2]}"
  hi="${BASH_REMATCH[3]}"
  if [ "$lo" -gt "$hi" ]; then
    echo "prepare-php.sh: patch '$bn' has inverted range LO=$lo > HI=$hi" >&2
    exit 1
  fi
  # Out of range — silently skip; expected for variant patches that
  # don't apply to this PHP version.
  if [ "$ver_num" -lt "$lo" ] || [ "$ver_num" -gt "$hi" ]; then
    continue
  fi
  # Collision check: two patches with the same NNNN both matching this
  # version is an authoring error (overlapping ranges).
  if [ -n "${group_seen[$group]:-}" ]; then
    echo "prepare-php.sh: patches '${group_seen[$group]}' and '$bn' both match PHP $PBS_VER_PHP_MAJORMINOR — overlapping @LO-HI ranges in NNNN group $group" >&2
    exit 1
  fi
  group_seen[$group]="$bn"
  selected_files+=("$patch_file")
done

if [ ${#selected_files[@]} -eq 0 ]; then
  echo "prepare-php.sh: no patches match PHP $PBS_VER_PHP_MAJORMINOR — refusing to build an unpatched tree" >&2
  exit 1
fi

echo "selected ${#selected_files[@]} patches:"
for p in "${selected_files[@]}"; do
  echo "  $(basename "$p")"
done

# Pass 2: apply patches in filename-sorted order. The per-patch comment
# header at the top of each .patch file documents what it does and why,
# so we don't repeat that here — let the patch's own header speak.
for patch_file in "${selected_files[@]}"; do
  echo "=== prepare-php: applying $(basename "$patch_file") ==="
  patch $PATCH_OPTS < "$patch_file"
done

# pbs_relocate.h — a minimal header-only helper resolving the install root
# at runtime. Header-only means no Makefile changes needed. Sites that
# consult build-time PHP_PREFIX / PHP_SYSCONFDIR / PHP_EXTENSION_DIR
# macros at runtime should prefer pbs_install_root() — that's what makes
# the tarball work after relocation. Several patches above #include this
# file.
#
# Cross-platform: the API (pbs_install_root) is identical; the
# implementation switches on __APPLE__:
#   - Linux: readlink("/proc/self/exe", ...)
#   - Darwin: _NSGetExecutablePath() + realpath() to canonicalize.
echo "=== prepare-php: drop pbs_relocate.h helper ==="
cat > main/pbs_relocate.h <<'CEOF'
/* PBS: runtime path resolution for relocatable installs.
 * The build-time PHP_PREFIX / PHP_SYSCONFDIR / PHP_EXTENSION_DIR macros
 * point at the build-time install path and remain useful as fallbacks,
 * but every callsite that consults them at runtime should prefer the
 * install-relative path computed from the running executable's path —
 * that's what makes the tarball work after relocation. */
#ifndef PHP_PBS_RELOCATE_H
#define PHP_PBS_RELOCATE_H

#include <unistd.h>
#include <limits.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

/* Compute the install root by stripping bin/<exe> off the running
 * binary's resolved absolute path. Writes a NUL-terminated absolute
 * path into buf, returns its length, or 0 on any failure (caller
 * should then fall back to compiled-in defaults). */
static inline size_t pbs_install_root(char *buf, size_t bufsize) {
    if (bufsize < 2) return 0;
#ifdef __APPLE__
    /* _NSGetExecutablePath may return a path that includes . / ..
     * components or a symlink, so we canonicalize via realpath().
     * realpath(path, NULL) allocates; copy into the caller's buf. */
    char raw[4096];
    uint32_t rawsize = sizeof(raw);
    if (_NSGetExecutablePath(raw, &rawsize) != 0) return 0;
    char *resolved = realpath(raw, NULL);
    if (!resolved) return 0;
    size_t rlen = strlen(resolved);
    if (rlen >= bufsize) { free(resolved); return 0; }
    memcpy(buf, resolved, rlen + 1);
    free(resolved);
#else
    ssize_t n = readlink("/proc/self/exe", buf, bufsize - 1);
    if (n <= 0) return 0;
    buf[n] = 0;
#endif
    /* /opt/php/bin/php → /opt/php/bin */
    char *p = strrchr(buf, '/');
    if (!p || p == buf) return 0;
    *p = 0;
    /* /opt/php/bin → /opt/php */
    p = strrchr(buf, '/');
    if (!p || p == buf) return 0;
    *p = 0;
    return strlen(buf);
}

#endif
CEOF
echo "  wrote main/pbs_relocate.h"

echo "prepare-php: done"
