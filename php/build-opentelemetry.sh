#!/usr/bin/env bash
# Build opentelemetry.so/.dylib (the opentelemetry PECL extension)
# against our just-built PHP. zend_observer bridge; see
# php/opentelemetry.nix.
#
# Mirrors build-redis.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so
# tarball-extension.nix can package it as a separately addressable
# extension artifact.
#
# No external C library — upstream's config.m4 leaves every dependency
# probe commented out and PHP_NEW_EXTENSION names only opentelemetry.c
# and otel_observer.c, so the manifest closure comes out empty.

set -euo pipefail

: "${PBS_SRC_OPENTELEMETRY:?}"
: "${PBS_VER_OPENTELEMETRY:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?opentelemetry needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/opentelemetry-${PBS_VER_OPENTELEMETRY}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_OPENTELEMETRY" -C "$PBS_SOURCES"
cd "$src_dir"

# Darwin: upstream's config.m4 passes "-Wall -Wextra -Werror
# -Wno-unused-parameter" as PHP_NEW_EXTENSION's cflags argument
# (config.m4:93), which PHP's build system appends to every per-object
# compile line *after* the CFLAGS we export. Our Darwin clang wrapper
# prepends `-Wl,-headerpad_max_install_names` to every invocation
# (toolchain-darwin.nix:49), including `-c` compile steps, so clang
# emits `'linker' input unused [-Wunused-command-line-argument]` and
# opentelemetry's -Werror turns it fatal on the very first object:
#
#   clang: error: -Wl,-headerpad_max_install_names: 'linker' input
#   unused [-Werror,-Wunused-command-line-argument]
#   make: *** [Makefile:209: opentelemetry.lo] Error 1
#
# -Qunused-arguments suppresses the warning's *emission*, so a later
# -Werror in any form has nothing to promote — the same fix, for the
# same reason, as php/build-spx.sh. (A `-Wno-error=unused-command-line-
# argument` would survive upstream's blanket -Werror on clang 21, but
# not a specific -Werror=unused-command-line-argument; -Qunused-arguments
# is order-independent by construction.) Linux's clang wrapper already
# bakes in -Wno-unused-command-line-argument, so this is Darwin-only.
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  export CFLAGS="$CFLAGS -Qunused-arguments"
fi

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-opentelemetry

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into opentelemetry's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

otel_so="$(find "$PBS_DEPS/__staging" -name opentelemetry.so -type f | head -1)"
if [ -z "$otel_so" ]; then
  echo "FATAL: opentelemetry.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${otel_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$otel_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" opentelemetry.so
echo "opentelemetry OK ($rel)"
