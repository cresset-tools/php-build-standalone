#!/usr/bin/env bash
# Build parallel.so/.dylib (the PECL userland-threads extension) against
# our just-built PHP. Pure C, no external library — same shape as
# build-pcov.sh.
#
# parallel needs a thread-safe interpreter: its config.m4 aborts with
# "parallel requires ZTS" otherwise. flake.nix only instantiates this for
# the zts flavor (sources.ztsOnlyExtensions), so a failure here on NTS
# means that gate was bypassed.
#
# A clean compile is not evidence that parallel works on a new PHP minor —
# it copies op_arrays between threads and breaks at runtime when the
# engine's structures move (unpatched 1.2.15 on 8.6 builds, then
# segfaults; php/parallel-fixes.patch carries the fixes). Before
# enabling a minor, run upstream's suite against the built tree:
#
#   cp <tree>/lib/build/run-tests.php /tmp/rt.php   # it writes beside itself
#   TEST_PHP_EXECUTABLE=<tree>/bin/php <tree>/bin/php -n /tmp/rt.php -n -q \
#     -d extension=<tree>/lib/extensions/<api>/parallel.so tests

set -euo pipefail

: "${PBS_SRC_PARALLEL:?}"
: "${PBS_VER_PARALLEL:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?parallel needs the PHP derivation for phpize/php-config}"
: "${PBS_PARALLEL_FIXES_PATCH:?unreleased upstream fixes (php/parallel-fixes.patch)}"

src_dir="$PBS_SOURCES/parallel-${PBS_VER_PARALLEL}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_PARALLEL" -C "$PBS_SOURCES"
cd "$src_dir"

# --fuzz=2 -p1 mirrors prepare-php.sh's PATCH_OPTS.
patch --fuzz=2 -p1 < "$PBS_PARALLEL_FIXES_PATCH"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-parallel

make -j"$NIX_BUILD_CORES"

make install INSTALL_ROOT="$PBS_DEPS/__staging"

parallel_so="$(find "$PBS_DEPS/__staging" -name parallel.so -type f | head -1)"
if [ -z "$parallel_so" ]; then
  echo "FATAL: parallel.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${parallel_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$parallel_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" parallel.so
echo "parallel OK ($rel)"
