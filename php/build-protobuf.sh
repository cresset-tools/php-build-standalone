#!/usr/bin/env bash
# Build protobuf.so/.dylib (the native Protocol Buffers PECL extension)
# against our just-built PHP. Pure C — the upb runtime is vendored in the
# PECL source, no external library. Same shape as build-apcu.sh /
# build-igbinary.sh.

set -euo pipefail

: "${PBS_SRC_PROTOBUF:?}"
: "${PBS_VER_PROTOBUF:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?protobuf needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/protobuf-${PBS_VER_PROTOBUF}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_PROTOBUF" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-protobuf

make -j"$NIX_BUILD_CORES"

make install INSTALL_ROOT="$PBS_DEPS/__staging"

protobuf_so="$(find "$PBS_DEPS/__staging" -name protobuf.so -type f | head -1)"
if [ -z "$protobuf_so" ]; then
  echo "FATAL: protobuf.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${protobuf_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$protobuf_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" protobuf.so
echo "protobuf OK ($rel)"
