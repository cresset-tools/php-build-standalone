#!/usr/bin/env bash
# Build amqp.so/.dylib (the amqp PECL extension) against our just-built
# PHP and bundled librabbitmq.
#
# Mirrors build-uv.sh: phpize + configure + make + staged install, with
# the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.

set -euo pipefail

: "${PBS_SRC_AMQP:?}"
: "${PBS_VER_AMQP:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?amqp needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_LIBRABBITMQ:?amqp needs librabbitmq headers + libs}"

src_dir="$PBS_SOURCES/amqp-${PBS_VER_AMQP}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_AMQP" -C "$PBS_SOURCES"
cd "$src_dir"

# config.m4 takes the pkg-config branch when --with-librabbitmq-dir is
# left at its default `yes`; that is also the branch that detects the
# rabbitmq-c/ header layout and enforces the >= 0.8.0 floor. Point it at
# the bundled prefix so it can't resolve a host librabbitmq.pc.
export PKG_CONFIG_PATH="$PBS_DEP_LIBRABBITMQ/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --with-amqp

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into amqp's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

amqp_so="$(find "$PBS_DEPS/__staging" -name amqp.so -type f | head -1)"
if [ -z "$amqp_so" ]; then
  echo "FATAL: amqp.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${amqp_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$amqp_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" amqp.so
echo "amqp OK ($rel)"
