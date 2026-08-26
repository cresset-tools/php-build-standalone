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

# 3. php -m must list the Debian-faithful static set that the bare
#    interpreter ships with. The interpreter tarball contains ZERO .so
#    files — every loadable
#    extension travels via its own per-ext tarball. The set below is the
#    intersection of modules statically linked into bin/php across every
#    supported PHP minor (8.1–8.5); 8.2+ also has random, and PHP 8.5+
#    statically builds opcache + ships lexbor/uri. Those version-specific
#    members are not asserted here.
emit "php -m"
modules=$("$PHP" -m) || die "php -m failed"
printf '%s\n' "$modules"
for ext in Core date filter hash json libxml openssl pcntl pcre \
           Reflection session sodium SPL standard zlib; do
    printf '%s\n' "$modules" | grep -qx "$ext" || \
        printf '%s\n' "$modules" | grep -qix "$ext" || \
        die "expected static module '$ext' not loaded"
done
# Forbidden: nothing that was moved to per-ext should appear in the bare
# interpreter's `php -m`. If something does, a configure flag flip got
# reverted upstream.
for ext in ctype dom fileinfo iconv mbstring intl curl gd PDO Phar \
           posix readline SimpleXML tokenizer xml xmlreader xmlwriter \
           mysqli mysqlnd sqlite3 ffi; do
    if printf '%s\n' "$modules" | grep -qx "$ext"; then
        die "ext '$ext' is in the bare interpreter — should ship as per-ext only"
    fi
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

# 4c. imagick must dlopen + version-check when the per-ext tarball has
#     been installed. After the Debian-aligned split (REFACTOR_DEBIAN_
#     ALIGNED.md), imagick.so is NEVER in the interpreter tarball — it
#     ships only via its per-ext tarball. The gate skips with a NOTICE
#     when imagick.so is absent (interpreter-only smoke run); set
#     IMAGICK_SO=<path> for explicit testing of the per-ext layout.
emit "imagick load"
_imagick_so="${IMAGICK_SO:-$ext_dir/imagick.so}"
if [ -f "$_imagick_so" ]; then
    out=$("$PHP" -dextension="$_imagick_so" \
                  -r 'echo "imagick=", phpversion("imagick"), "\n";') \
        || die "imagick load failed"
    printf '%s\n' "$out"
    case "$out" in imagick=*) : ;; *) die "imagick did not report a version: $out" ;; esac
else
    emit "NOTICE: imagick.so not found at $_imagick_so — skipping imagick dlopen gate (per-ext tarball not extracted)"
fi

# 4d. spx (php-spx profiler) must dlopen + version-check when its per-ext
#     tarball has been installed. Like imagick, spx.so is NEVER in the
#     interpreter tarball — it ships only via its per-ext tarball. spx is a
#     regular `extension=` module (NOT a zend_extension), so it loads via
#     -dextension, not -dzend_extension. The gate skips with a NOTICE when
#     spx.so is absent; set SPX_SO=<path> for explicit per-ext layout testing.
emit "spx load"
_spx_so="${SPX_SO:-$ext_dir/spx.so}"
if [ -f "$_spx_so" ]; then
    out=$("$PHP" -dextension="$_spx_so" \
                  -r 'echo "spx=", phpversion("spx"), "\n";') \
        || die "spx load failed"
    printf '%s\n' "$out"
    case "$out" in spx=*) : ;; *) die "spx did not report a version: $out" ;; esac

    # Web-UI relocation: when the per-ext tarball is extracted with its
    # share/php-spx/assets/web-ui tree adjacent to the .so, spx must default
    # spx.http_ui_assets_dir to those bundled assets with NO php.ini change —
    # resolved relative to the .so itself (dladdr), so the HTTP flame-graph UI
    # works wherever the tarball was unpacked. Gated on the assets actually
    # being present (the bare $ext_dir/spx.so layout has none → NOTICE).
    _spx_assets="$(CDPATH= cd -- "$(dirname "$_spx_so")/../../../share/php-spx/assets/web-ui" 2>/dev/null && pwd)"
    if [ -n "$_spx_assets" ] && [ -f "$_spx_assets/index.html" ]; then
        ui=$("$PHP" -dextension="$_spx_so" \
                     -r 'echo ini_get("spx.http_ui_assets_dir");') \
            || die "spx web-ui assets-dir query failed"
        [ "$ui" = "$_spx_assets" ] \
            || die "spx.http_ui_assets_dir did not relocate to the bundled assets: got '$ui', want '$_spx_assets'"
        [ -f "$ui/index.html" ] \
            || die "spx web-ui index.html missing under relocated assets dir $ui"
        emit "spx web-ui assets relocate OK ($ui)"
    else
        emit "NOTICE: spx web-ui assets not adjacent to $_spx_so — skipping web-ui relocation gate"
    fi
else
    emit "NOTICE: spx.so not found at $_spx_so — skipping spx dlopen gate (per-ext tarball not extracted)"
fi

# 4e. ReactPHP event-loop backends. Three per-ext tarballs stand behind
#     React\EventLoop's non-default loops: uv → ExtUvLoop, ev → ExtEvLoop,
#     event → ExtEventLoop. Each gate skips with a NOTICE when its .so
#     isn't extracted alongside /php; set UV_SO / EV_SO / EVENT_SO to test
#     an explicit path.
#
#     ev.so and event.so both reference `socket_ce`, a *data* symbol
#     exported by sockets.so, and PHP dlopens with RTLD_LAZY|RTLD_GLOBAL —
#     which defers function relocations but binds data ones eagerly. So
#     those two load only with sockets.so already loaded, which is why
#     their conf.d fragments ship at prefix 40 (after 20-sockets.ini).
#     These gates pin that contract: sockets is loaded explicitly, and
#     each extension is asserted to publish the symbol ReactPHP's Factory
#     probes for when it picks a loop.
emit "reactphp event-loop backends"
_sockets_so="${SOCKETS_SO:-$ext_dir/sockets.so}"

# Every probe below runs under -n. These three DO ship auto-loading conf.d
# fragments, so without -n the fragment loads the extension first and the
# explicit -dextension= is a "Module already loaded" warning that lands in
# $out. -n also makes each gate hermetic: it proves the .so loads given
# exactly its stated prerequisites and nothing else, which is what makes
# the sockets pairing above a real assertion rather than an artifact of
# conf.d ordering. extension_dir still resolves — the relocation patch
# computes it from /proc/self/exe at startup, not from php.ini — and the
# paths passed here are absolute regardless.

# uv needs no such pairing — upstream declares socket_ce weak and fills it
# with DL_FETCH_SYMBOL at MINIT, so uv.so must load entirely on its own.
# Loading it bare here is the assertion.
_uv_so="${UV_SO:-$ext_dir/uv.so}"
if [ -f "$_uv_so" ]; then
    out=$("$PHP" -n -dextension="$_uv_so" \
                  -r 'echo function_exists("uv_loop_new") ? "uv=ok\n" : "uv=missing\n";') \
        || die "uv load failed"
    printf '%s\n' "$out"
    [ "$out" = "uv=ok" ] || die "uv did not register uv_loop_new(): $out"
else
    emit "NOTICE: uv.so not found at $_uv_so — skipping ExtUvLoop gate"
fi

_ev_so="${EV_SO:-$ext_dir/ev.so}"
if [ -f "$_ev_so" ] && [ -f "$_sockets_so" ]; then
    out=$("$PHP" -n -dextension="$_sockets_so" -dextension="$_ev_so" \
                  -r 'echo class_exists("EvLoop") ? "ev=ok\n" : "ev=missing\n";') \
        || die "ev load failed (sockets.so must load first — see the note above)"
    printf '%s\n' "$out"
    [ "$out" = "ev=ok" ] || die "ev did not register the EvLoop class: $out"
elif [ -f "$_ev_so" ]; then
    emit "NOTICE: sockets.so not found at $_sockets_so — skipping ExtEvLoop gate (ev.so cannot load without it)"
else
    emit "NOTICE: ev.so not found at $_ev_so — skipping ExtEvLoop gate"
fi

_event_so="${EVENT_SO:-$ext_dir/event.so}"
if [ -f "$_event_so" ] && [ -f "$_sockets_so" ]; then
    out=$("$PHP" -n -dextension="$_sockets_so" -dextension="$_event_so" \
                  -r 'echo class_exists("EventBase") ? "event=ok\n" : "event=missing\n";') \
        || die "event load failed (sockets.so must load first — see the note above)"
    printf '%s\n' "$out"
    [ "$out" = "event=ok" ] || die "event did not register the EventBase class: $out"
elif [ -f "$_event_so" ]; then
    emit "NOTICE: sockets.so not found at $_sockets_so — skipping ExtEventLoop gate (event.so cannot load without it)"
else
    emit "NOTICE: event.so not found at $_event_so — skipping ExtEventLoop gate"
fi

# 4b. opcache (zend_extension): on PHP 8.5+ it's built statically into
#     bin/php and registers automatically. On 8.1–8.4 opcache.so ships
#     only as a per-ext tarball, so the bare interpreter has no opcache
#     loaded. Detect the layout: if opcache.so is present in extension_dir
#     (per-ext extracted alongside /php), load it explicitly via
#     -dzend_extension and verify. If absent, skip if-and-only-if PHP < 8.5;
#     fail if 8.5+ (where opcache is supposed to be static).
emit "opcache load"
php_major_minor=$("$PHP" -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;')
ext_dir=$("$PHP" -r 'echo ini_get("extension_dir");' 2>/dev/null)
_opcache_so="${OPCACHE_SO:-$ext_dir/opcache.so}"
if [ -f "$_opcache_so" ]; then
    out=$("$PHP" -dzend_extension="$_opcache_so" \
                  -r 'echo extension_loaded("Zend OPcache") ? "opcache=ok\n" : "opcache=missing\n";') \
        || die "opcache load failed"
elif [ "$php_major_minor" = "8.5" ] || [ "$php_major_minor" \> "8.5" ]; then
    # 8.5+: opcache is static-built; should be loaded without any -d flag.
    out=$("$PHP" -r 'echo extension_loaded("Zend OPcache") ? "opcache=ok\n" : "opcache=missing\n";') \
        || die "opcache load failed"
else
    emit "NOTICE: opcache.so not found at $_opcache_so on PHP $php_major_minor — skipping (per-ext tarball not extracted)"
    out="opcache=ok"
fi
printf '%s\n' "$out"
case "$out" in opcache=ok) : ;; *) die "opcache did not register: $out" ;; esac

# 5. libxml is built static into bin/php — exercise the bundled libxml2
#    store path through PHP's procedural libxml_* functions (no dom.so
#    needed; dom is a per-ext now and not loaded by default). If dom.so
#    is extracted alongside /php, additionally verify a DOMDocument
#    roundtrip; otherwise the static probe is sufficient.
emit "libxml (static)"
out=$("$PHP" -r '
    libxml_use_internal_errors(true);
    libxml_clear_errors();
    if (libxml_use_internal_errors() !== true) { echo "fail-flag\n"; exit; }
    if (libxml_get_errors() !== []) { echo "fail-clear\n"; exit; }
    echo "ok\n";
') || die "libxml static probe failed"
printf '%s\n' "$out"
[ "$out" = "ok" ] || die "libxml static probe got '$out'"

_dom_so="${DOM_SO:-$ext_dir/dom.so}"
if [ -f "$_dom_so" ]; then
    emit "dom + libxml2 roundtrip (per-ext extracted)"
    out=$("$PHP" -dextension="$_dom_so" -r '
        $d = new DOMDocument();
        $d->loadXML("<r><n>hi</n></r>");
        $xp = new DOMXPath($d);
        echo $xp->query("/r/n")->item(0)->textContent, "\n";
    ') || die "dom roundtrip failed"
    printf '%s\n' "$out"
    [ "$out" = "hi" ] || die "dom roundtrip got '$out', expected 'hi'"
fi

# 6. openssl must complete a real handshake-equivalent op (not just load).
emit "openssl + hash"
out=$("$PHP" -r 'echo bin2hex(openssl_random_pseudo_bytes(8)), " ",
    hash("sha256", "abc"), "\n";') || die "openssl op failed"
printf '%s\n' "$out"

# 6b. sodium (libsodium) keypair + signature roundtrip — exercises the
#     bundled libsodium and confirms ext/sodium loads correctly.
emit "sodium signature roundtrip"
out=$("$PHP" -r '
    $kp = sodium_crypto_sign_keypair();
    $sig = sodium_crypto_sign_detached("msg",
        sodium_crypto_sign_secretkey($kp));
    echo sodium_crypto_sign_verify_detached($sig, "msg",
        sodium_crypto_sign_publickey($kp)) ? "ok\n" : "fail\n";
') || die "sodium op failed"
printf '%s\n' "$out"
[ "$out" = "ok" ] || die "sodium roundtrip did not verify: $out"

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
