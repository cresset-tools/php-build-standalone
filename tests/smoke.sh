#!/bin/sh
# Run inside a distro container against /php (mounted, read-only).
# POSIX sh on purpose — Alpine's /bin/sh is busybox ash, not bash.
#
# Exits 0 on success, non-zero on the first failed gate. Each gate prints a
# one-line PASS/FAIL so the orchestrator's logs make the failure obvious.

set -eu

PHP=/php/bin/php

emit() { printf '[smoke] %s\n' "$*"; }
die()  { printf '[smoke] FAIL: %s\n' "$*" >&2; exit 1; }

# 0. Distro fingerprint — useful in failure logs.
emit "uname: $(uname -srm)"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    emit "distro: ${PRETTY_NAME:-${NAME:-unknown}}"
fi
# ldd --version's first line carries the libc flavour and version.
if command -v ldd >/dev/null 2>&1; then
    emit "ldd: $(ldd --version 2>&1 | head -n1)"
fi

# 1. The interpreter must exist. This is the single biggest reason the
#    tarball can fail on a host (NixOS, musl distros).
if [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
    die "/lib64/ld-linux-x86-64.so.2 missing — host has no glibc loader at the expected path"
fi

# 2. php -v must succeed.
emit "php -v"
"$PHP" -v || die "php -v failed"

# 3. php -m must list the bundled extensions that are auto-loaded. Note:
#    opcache and xdebug are zend_extensions and are NOT auto-loaded — they
#    have dedicated gates below that exercise dlopen via -dzend_extension.
emit "php -m"
modules=$("$PHP" -m) || die "php -m failed"
printf '%s\n' "$modules"
for ext in Core curl date dom intl json mbstring openssl pcre pdo_sqlite \
           sodium sqlite3 zip zlib iconv; do
    printf '%s\n' "$modules" | grep -qx "$ext" || \
        printf '%s\n' "$modules" | grep -qix "$ext" || \
        die "expected extension '$ext' not loaded"
done

# 4. xdebug must dlopen and report its version. This is the central use
#    case the project exists for — static-php-cli can't do this.
emit "xdebug load"
out=$("$PHP" -dzend_extension=xdebug \
              -r 'echo "xdebug=", phpversion("xdebug"), "\n";') \
    || die "xdebug load failed"
printf '%s\n' "$out"
case "$out" in xdebug=*) : ;; *) die "xdebug did not report a version: $out" ;; esac

# 4b. opcache (zend_extension, shipped but not auto-loaded) must dlopen.
#     Resolved via the bundled extension_dir + the short-name 'opcache'.
emit "opcache load"
out=$("$PHP" -dzend_extension=opcache \
              -r 'echo extension_loaded("Zend OPcache") ? "opcache=ok\n" : "opcache=missing\n";') \
    || die "opcache load failed"
printf '%s\n' "$out"
case "$out" in opcache=ok) : ;; *) die "opcache did not register: $out" ;; esac

# 5. intl (ICU) must format a currency — exercises the bundled libicu.
emit "intl currency"
out=$("$PHP" -r 'echo NumberFormatter::create("en_US",
    NumberFormatter::CURRENCY)->formatCurrency(1234.56, "USD"), "\n";') \
    || die "intl format failed"
printf '%s\n' "$out"

# 6. openssl must complete a real handshake-equivalent op (not just load).
emit "openssl + hash"
out=$("$PHP" -r 'echo bin2hex(openssl_random_pseudo_bytes(8)), " ",
    hash("sha256", "abc"), "\n";') || die "openssl op failed"
printf '%s\n' "$out"

# 7. Relocation: extension_dir is computed from /proc/self/exe at runtime,
#    so it should track wherever bin/php currently lives. The mount point
#    is /php here.
emit "relocation: extension_dir tracks /proc/self/exe"
ext_dir=$("$PHP" -r 'echo ini_get("extension_dir");') \
    || die "ini_get(extension_dir) failed"
emit "extension_dir=$ext_dir"
case "$ext_dir" in
    /php/lib/extensions/*) : ;;
    *) die "extension_dir=$ext_dir did not resolve under /php" ;;
esac

emit "ALL GATES PASSED"
