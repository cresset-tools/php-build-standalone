#!/usr/bin/env bash
# Build excimer.so/.dylib (the excimer PECL extension) against our
# just-built PHP. Sampling profiler; see php/excimer.nix.
#
# Mirrors build-redis.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so
# tarball-extension.nix can package it as a separately addressable
# extension artifact.
#
# No external C library. config.m4 picks a timer backend by probing the
# platform: SIGEV_THREAD_ID present -> timerlib/timerlib_posix.c plus
# `AC_CHECK_LIB(rt, timer_create)`; otherwise kqueue ->
# timerlib/timerlib_kqueue.c. Linux takes the first branch, Darwin the
# second. Both resolve against libc/librt, so nothing lands in the
# extension's store closure.
#
# The CentOS 7 sysroot is doing real work here. config.m4 also probes for
# `gettid` (glibc 2.30+) and `pthread_attr_setsigmask_np` (glibc 2.32+).
# At our 2.17 floor neither is declared, both probes fail, and excimer
# compiles its portable fallbacks instead — which is precisely the build
# we want to ship to a manylinux2014-baseline consumer. A build against a
# modern host glibc would silently bake in the newer symbols and raise the
# floor.

set -euo pipefail

: "${PBS_SRC_EXCIMER:?}"
: "${PBS_VER_EXCIMER:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?excimer needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/excimer-${PBS_VER_EXCIMER}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_EXCIMER" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-excimer

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into excimer's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

excimer_so="$(find "$PBS_DEPS/__staging" -name excimer.so -type f | head -1)"
if [ -z "$excimer_so" ]; then
  echo "FATAL: excimer.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${excimer_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$excimer_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" excimer.so
echo "excimer OK ($rel)"
