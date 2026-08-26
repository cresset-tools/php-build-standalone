#!/usr/bin/env bash
# Build ev.so/.dylib (the ev PECL extension) against our just-built PHP.
# ReactPHP drives it as ExtEvLoop.
#
# Mirrors build-redis.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so
# tarball-extension.nix can package it as a separately addressable
# extension artifact.
#
# No external C library: config.m4 compiles the vendored libev/ subtree
# in-tree via PHP_ADD_BUILD_DIR, so libev's epoll/kqueue backends are
# statically part of ev.so and the extension's store closure is just
# PHP's.
#
# ev.so DOES take one symbol from another extension. common.h enables
# its ext/sockets integration under `#if HAVE_SOCKETS`, which PHP's
# main/php_config.h defines whenever ext/sockets was configured at all —
# including our --enable-sockets=shared. util.c then references
# `socket_ce`, a *data* symbol exported by sockets.so. PHP dlopens
# extensions with RTLD_LAZY|RTLD_GLOBAL and RTLD_LAZY defers only
# function relocations, so that reference is bound eagerly: ev.so fails
# to load unless sockets.so was loaded first. The 40- conf.d prefix in
# flake.nix is what orders that, matching the msgpack/session precedent.

set -euo pipefail

: "${PBS_SRC_EV:?}"
: "${PBS_VER_EV:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?ev needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/ev-${PBS_VER_EV}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_EV" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-ev

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into ev's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

ev_so="$(find "$PBS_DEPS/__staging" -name ev.so -type f | head -1)"
if [ -z "$ev_so" ]; then
  echo "FATAL: ev.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${ev_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$ev_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" ev.so
echo "ev OK ($rel)"
