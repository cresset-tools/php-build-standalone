#!/usr/bin/env bash
# prepare-php.sh — patch PHP source files BEFORE configure runs.
#
# The headline patch: rewrite scripts/phpize.in and scripts/php-config.in
# so the prefix is computed at runtime from $0 instead of being hardcoded
# to the build-time install path. Without this, every relocated tarball is
# broken — `pecl install <ext>` against the moved tarball fails because
# phpize emits the wrong include / build-files path.
#
# We replace @prefix@ / @exec_prefix@ / @libdir@ / @includedir@ /
# @datarootdir@ / @bindir@ / @mandir@ literal placeholders with
# `$prefix/...` shell expressions and define `prefix` from the script's
# own location. configure won't substitute what's no longer @-tagged.
#
# Inputs: cwd is the unpacked PHP source tree.

set -euo pipefail

if [ ! -f scripts/phpize.in ] || [ ! -f scripts/php-config.in ]; then
  echo "prepare-php.sh: must be run from the unpacked PHP source tree" >&2
  exit 1
fi

echo "=== prepare-php: patch scripts/phpize.in ==="
# Replaces build-time @prefix@ / @libdir@ / @includedir@ / @datarootdir@ /
# @exec_prefix@ / @SED@ substitutions with runtime path computation from $0,
# and simplifies phpize_replace_prefix() to a plain copy (phpize.m4 has no
# @prefix@ placeholders in modern PHP).
patch -p1 < "${PBS_PHP_PATCHES_DIR}/0001-relocate-phpize.patch"
echo "  patched scripts/phpize.in"

echo "=== prepare-php: patch scripts/php-config.in ==="
# Replaces build-time @prefix@ / @datarootdir@ / @exec_prefix@ / @SED@ /
# @includedir@ / @orig_libdir@ / @mandir@ / @bindir@ substitutions with
# runtime path computation from $0.
patch -p1 < "${PBS_PHP_PATCHES_DIR}/0002-relocate-php-config.patch"
echo "  patched scripts/php-config.in"

echo "=== prepare-php: drop pbs_relocate.h helper ==="
# A minimal header-only helper that resolves the install root from
# /proc/self/exe at runtime. Header-only means no Makefile changes needed.
cat > main/pbs_relocate.h <<'CEOF'
/* PBS: runtime path resolution for relocatable installs.
 * The build-time PHP_PREFIX / PHP_SYSCONFDIR / PHP_EXTENSION_DIR macros
 * point at the build-time install path and remain useful as fallbacks,
 * but every callsite that consults them at runtime should prefer the
 * install-relative path computed from /proc/self/exe — that's what makes
 * the tarball work after relocation. */
#ifndef PHP_PBS_RELOCATE_H
#define PHP_PBS_RELOCATE_H

#include <unistd.h>
#include <limits.h>
#include <string.h>
#include <stdio.h>

/* Compute the install root by stripping bin/<exe> off /proc/self/exe.
 * Writes a NUL-terminated absolute path into buf, returns its length, or
 * 0 on any failure (caller should then fall back to compiled-in defaults). */
static inline size_t pbs_install_root(char *buf, size_t bufsize) {
    if (bufsize < 2) return 0;
    ssize_t n = readlink("/proc/self/exe", buf, bufsize - 1);
    if (n <= 0) return 0;
    buf[n] = 0;
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

echo "=== prepare-php: patch main/php_ini.c (php.ini search path) ==="
# Adds <install_root>/etc before PHP_CONFIG_FILE_PATH in the search list, and
# relocates the conf.d scan-dir fallback to <install_root>/etc/conf.d.
patch -p1 < "${PBS_PHP_PATCHES_DIR}/0003-relocate-php-ini-search.patch"
echo "  patched main/php_ini.c"

echo "=== prepare-php: patch main/main.c (extension_dir runtime override) ==="
# Injects an extension_dir runtime override after zend_register_standard_ini_entries()
# to rebase the extension path on the runtime install root.
patch -p1 < "${PBS_PHP_PATCHES_DIR}/0004-relocate-extension-dir-startup.patch"
echo "  patched main/main.c"

echo "=== prepare-php: patch sapi/cli/php_cli.c (--ini display) ==="
# Makes `php --ini` print <install_root>/etc instead of the Nix store path.
patch -p1 < "${PBS_PHP_PATCHES_DIR}/0005-relocate-cli-ini-display.patch"
echo "  patched sapi/cli/php_cli.c"

echo "=== prepare-php: patch sapi/fpm/fpm/fpm_conf.c (prefix + sysconfdir) ==="
# Relocates PHP_PREFIX (used for $prefix expansion in pool configs) and the
# default php-fpm.conf path from PHP_SYSCONFDIR to <install_root>/etc/.
patch -p1 < "${PBS_PHP_PATCHES_DIR}/0006-relocate-fpm-paths.patch"
echo "  patched sapi/fpm/fpm/fpm_conf.c (2 sites)"

echo "prepare-php: done"
