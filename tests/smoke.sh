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

# 2b. Running a script file must shut down cleanly. `php -v` skips the
#     request lifecycle and so doesn't exercise zend_deactivate /
#     zend_ini_deactivate; only a real script invocation does. A regression
#     in the extension_dir relocation patch (or anything else that mutates
#     INI at MINIT) shows up here as exit 139 on an otherwise trivial run.
emit "request shutdown clean"
script=$(mktemp /tmp/php-smoke-XXXX.php)
printf '<?php echo "ok\\n";\n' > "$script"
out=$("$PHP" "$script" 2>&1); rc=$?
rm -f "$script"
[ "$rc" -eq 0 ] || die "php script.php exited rc=$rc (139 = zend_ini_deactivate segfault); output: $out"
[ "$out" = "ok" ] || die "php script.php produced unexpected output: $out"

# 3. php -m must list the bundled extensions that are auto-loaded. Note:
#    opcache and xdebug are zend_extensions and are NOT auto-loaded — they
#    have dedicated gates below that exercise dlopen via -dzend_extension.
emit "php -m"
modules=$("$PHP" -m) || die "php -m failed"
printf '%s\n' "$modules"
for ext in Core curl date dom exif intl json mbstring openssl pcre pdo_sqlite \
           pdo_pgsql pgsql sodium sqlite3 zip zlib iconv; do
    printf '%s\n' "$modules" | grep -qx "$ext" || \
        printf '%s\n' "$modules" | grep -qix "$ext" || \
        die "expected extension '$ext' not loaded"
done

# 4. xdebug must dlopen and report its version. This is the central use
#    case the project exists for — static-php-cli can't do this.
#
#    Phase 3: xdebug ships as a separate per-extension tarball, not inside
#    the interpreter tarball. The smoke test accepts both layouts:
#      (a) xdebug.so present in extension_dir → loaded, version verified.
#      (b) xdebug.so absent (interpreter-only smoke run) → gate skipped with
#          a notice. The per-extension tarball smoke test covers (b) separately.
#
#    XDEBUG_SO can be set by the caller to an explicit path for layout (b)
#    test scenarios, e.g. XDEBUG_SO=/xdebug-ext/lib/extensions/.../xdebug.so
emit "xdebug load"
ext_dir=$("$PHP" -r 'echo ini_get("extension_dir");' 2>/dev/null)
_xdebug_so="${XDEBUG_SO:-$ext_dir/xdebug.so}"
if [ -f "$_xdebug_so" ]; then
    out=$("$PHP" -dzend_extension="$_xdebug_so" \
                  -r 'echo "xdebug=", phpversion("xdebug"), "\n";') \
        || die "xdebug load failed"
    printf '%s\n' "$out"
    case "$out" in xdebug=*) : ;; *) die "xdebug did not report a version: $out" ;; esac
else
    emit "NOTICE: xdebug.so not found at $_xdebug_so — interpreter-only smoke run, skipping xdebug dlopen gate"
    emit "NOTICE: run with XDEBUG_SO=<path> or extract the per-extension tarball alongside /php to test xdebug"
fi

# 4b. opcache (zend_extension) must register. On 8.1-8.4 it ships as
#     opcache.so loaded by the 10-opcache.ini conf.d fragment; on 8.5+
#     it's built statically into bin/php and no conf.d fragment is
#     emitted. Both paths show up to userland identically as
#     "Zend OPcache" via extension_loaded(), so the gate asks PHP
#     directly without -dzend_extension (which on 8.5 would emit a
#     "Failed loading" startup warning to stdout because opcache.so
#     doesn't exist).
emit "opcache load"
out=$("$PHP" -r 'echo extension_loaded("Zend OPcache") ? "opcache=ok\n" : "opcache=missing\n";') \
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

# 8. V2 store layout: bundled C-library deps live under store/ not lib/.
#    Confirm store/ exists and has at least the openssl and zlib dirs.
emit "store layout: store/ contains content-addressed dep dirs"
[ -d /php/store ] || die "store/ directory missing (V2 layout)"
[ -d /php/store/openssl-3.5.6-wxm1p9wc ] || \
    ls /php/store/ | grep -q '^openssl-' || \
    die "no openssl store path found under store/"
[ -d /php/store/zlib-1.3.1-xr8a5w5j ] || \
    ls /php/store/ | grep -q '^zlib-' || \
    die "no zlib store path found under store/"
emit "store/ contains $(ls /php/store/ | wc -l) dep dirs"

emit "ALL GATES PASSED"
