#!/usr/bin/env bash
# Build pcov.so/.dylib (the PECL code-coverage extension) against our
# just-built PHP. Pure C, no external library — same shape as build-apcu.sh.
#
# pcov collects line-level coverage data via Zend opcode hooks; it's a Zend
# extension (zend_extension=pcov) when loaded for coverage, though the .so
# also exposes a regular module surface so test runners can interrogate
# its presence via extension_loaded('pcov'). Auto-loading is intentionally
# opt-in in the per-ext tarball (confFragment=null), matching xdebug:
# coverage is a per-run flag, not always-on instrumentation.

set -euo pipefail

: "${PBS_SRC_PCOV:?}"
: "${PBS_VER_PCOV:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?pcov needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/pcov-${PBS_VER_PCOV}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_PCOV" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-pcov

make -j"$NIX_BUILD_CORES"

make install INSTALL_ROOT="$PBS_DEPS/__staging"

pcov_so="$(find "$PBS_DEPS/__staging" -name pcov.so -type f | head -1)"
if [ -z "$pcov_so" ]; then
  echo "FATAL: pcov.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${pcov_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$pcov_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" pcov.so
echo "pcov OK ($rel)"
