#!/usr/bin/env bash
# Build uv.so/.dylib (the uv PECL extension) against our just-built PHP
# and bundled libuv. ReactPHP drives it as ExtUvLoop.
#
# Mirrors build-imagick.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so
# tarball-extension.nix can package it as a separately addressable
# extension artifact.
#
# Unlike ev.so and event.so, uv.so has no hard link to ext/sockets:
# php_uv.c declares `zend_class_entry *socket_ce` with
# __attribute__((weak)) and fills it at MINIT via DL_FETCH_SYMBOL
# against the already-loaded sockets module, so the .so dlopens with or
# without sockets present and needs no conf.d ordering.

set -euo pipefail

: "${PBS_SRC_UV:?}"
: "${PBS_VER_UV:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?uv needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_LIBUV:?uv needs libuv headers + libs}"

src_dir="$PBS_SOURCES/uv-${PBS_VER_UV}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_UV" -C "$PBS_SOURCES"
cd "$src_dir"

# config.m4's preferred path is `$PKG_CONFIG --exists libuv`, which is
# also the only branch that enforces the >= 1.0.0 floor. Point it at the
# bundled prefix so it can't resolve a host libuv.pc. (The fallback
# branch searches /usr/local and /usr, which inside the Nix sandbox
# would find nothing.)
export PKG_CONFIG_PATH="$PBS_DEP_LIBUV/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --with-uv

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into uv's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

uv_so="$(find "$PBS_DEPS/__staging" -name uv.so -type f | head -1)"
if [ -z "$uv_so" ]; then
  echo "FATAL: uv.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${uv_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$uv_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" uv.so
echo "uv OK ($rel)"
