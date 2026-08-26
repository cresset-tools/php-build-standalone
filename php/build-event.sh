#!/usr/bin/env bash
# Build event.so/.dylib (the event PECL extension) against our just-built
# PHP and bundled libevent. ReactPHP drives it as ExtEventLoop.
#
# Mirrors build-imagick.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so
# tarball-extension.nix can package it as a separately addressable
# extension artifact.
#
# The extension links three of libevent's four modular libraries:
#   event_core    the loop itself (epoll / kqueue)
#   event_extra   evdns / evhttp / evconnlistener — the Event* classes
#                 beyond the loop (--with-event-extra, default yes)
#   event_openssl EventSslContext + EventBufferEvent::sslSocket()
#                 (--with-event-openssl, default yes)
# event_pthreads is deliberately left out: --with-event-pthreads
# defaults to no, and thread-safe libevent is only meaningful for a
# ZTS SAPI sharing one event_base across threads, which is not how
# ReactPHP (or anything else consuming this bundle) uses it.
#
# event.so DOES take one symbol from another extension. Under
# --enable-event-sockets (default yes) common.h pulls in
# ext/sockets/php_sockets.h and util.c/event_util.c reference
# `socket_ce`, a *data* symbol exported by sockets.so. PHP dlopens
# extensions with RTLD_LAZY|RTLD_GLOBAL and RTLD_LAZY defers only
# function relocations, so that reference is bound eagerly: event.so
# fails to load unless sockets.so was loaded first. The 40- conf.d
# prefix in flake.nix is what orders that, matching the msgpack/session
# precedent.

set -euo pipefail

: "${PBS_SRC_EVENT:?}"
: "${PBS_VER_EVENT:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?event needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_LIBEVENT:?event needs libevent headers + libs}"
: "${PBS_DEP_OPENSSL:?event needs OpenSSL for libevent_openssl support}"

src_dir="$PBS_SOURCES/event-${PBS_VER_EVENT}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_EVENT" -C "$PBS_SOURCES"
cd "$src_dir"

# config.m4 calls PHP's own PHP_SETUP_OPENSSL macro, which resolves
# OpenSSL through pkg-config (the --with-openssl-dir argument it also
# declares is vestigial on PHP 8). Point that at the bundled prefix so
# it can't pick up a host openssl.pc. libevent itself is located by
# --with-event-libevent-dir below, not by pkg-config.
export PKG_CONFIG_PATH="$PBS_DEP_OPENSSL/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PBS_DEP_PHP/bin/phpize"

# --with-event-libevent-dir is the prefix config.m4 probes for
# include/event2/event.h; it also derives -L<prefix>/$PHP_LIBDIR from it
# for the three AC_CHECK_LIB link probes. --with-event-core takes no
# directory here (it would be searched as a prefix too, but the
# dedicated option is the documented spelling).
./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --with-event-core \
  --with-event-extra \
  --with-event-openssl \
  --with-event-libevent-dir="$PBS_DEP_LIBEVENT" \
  --enable-event-sockets

# configure regenerates php8/php_event.stub.php from its .in (that's how
# --with-event-ns would rewrite the namespace), which leaves the stub
# newer than the shipped php_event_arginfo.h and fires PHP's gen_stub.php
# rule. That rule runs $PBS_DEP_PHP/bin/php, and the PHP dep is not
# finalized yet — its $ORIGIN RPATHs are written by finalize at tree time
# — so on its own it cannot resolve libssl / libz / libxml2.
#
# $PBS_PHP_LDPATH (set by php/event.nix from PHP's
# passthru.transitiveBundledDeps) covers bin/php's whole bundled closure;
# $PBS_DEPS_LDPATH covers this derivation's own direct deps. Scoped to
# the make invocations only — setup-env deliberately never exports a
# library path globally, because a modern-glibc build tool that picked up
# the sysroot's libc would die with "GLIBC_2.34 not found".
#
# Both are empty on Darwin by design (see php/event.nix), where dyld
# resolves bin/php's deps through absolute install_names instead — so
# `make` runs unwrapped there rather than with an empty
# DYLD_LIBRARY_PATH.
php_ldpath="${PBS_PHP_LDPATH:-}${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}"
php_ldpath="${php_ldpath#:}"

make_env=()
if [ -n "$php_ldpath" ]; then
  make_env=(env "$PBS_RPATH_VAR=$php_ldpath")
fi

"${make_env[@]}" make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into event's own $out.
"${make_env[@]}" make install INSTALL_ROOT="$PBS_DEPS/__staging"

event_so="$(find "$PBS_DEPS/__staging" -name event.so -type f | head -1)"
if [ -z "$event_so" ]; then
  echo "FATAL: event.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${event_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$event_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" event.so
echo "event OK ($rel)"
