#!/usr/bin/env bash
# Build snappy.so/.dylib (the snappy PHP extension) against our just-built
# PHP.
#
# Mirrors build-lz4.sh: phpize + configure + make + staged install, with
# the resulting .so copied into this dep's $out so tarball-extension.nix
# can package it as a separately addressable extension artifact.
#
# No external C library: the source tarball vendors Google's snappy
# (snappy/, 1.2.1 as of 0.2.3) and config.m4 compiles it in-tree when no
# system library is requested, so the compressor is statically part of
# snappy.so and the extension's store closure is just PHP's. (Its APCu
# serializer hook is keyed on apcu's header being in PHP's include dir,
# which it never is here, so there is no flag to pass for it.)
#
# Unlike zstd / lz4 / lzf, vendored snappy is C++. config.m4 adds an
# explicit `-lstdc++` to SNAPPY_SHARED_LIBADD, which on Linux would put
# libstdc++.so.6 into DT_NEEDED: outside the LSB set our policy allows and
# not guaranteed on a minimal container. -static-libstdc++ does not help:
# it is a clang++ driver flag, and libtool links the module through cc.
# So on Linux the generated Makefile's -lstdc++ is replaced with the
# toolchain's libstdc++.a, passed positionally — the same trick
# build-php-pre-configure-{linux,musl}.sh use for bin/php, and both
# toolchains expose the archive at $PBS_TOOLCHAIN/lib/libstdc++.a. On
# Darwin libc++ is part of the OS and stays dynamic, like ICU.

set -euo pipefail

: "${PBS_SRC_SNAPPY:?}"
: "${PBS_VER_SNAPPY:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?snappy needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/snappy-${PBS_VER_SNAPPY}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_SNAPPY" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

linux=0
[ "$(uname -s)" = "Linux" ] && linux=1

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-snappy

if [ "$linux" = 1 ]; then
  grep -q -- '-lstdc++' Makefile || {
    echo "FATAL: expected config.m4 to add -lstdc++ to the Makefile" >&2
    exit 1
  }
  libstdcxx_a="${PBS_TOOLCHAIN:?}/lib/libstdc++.a"
  [ -f "$libstdcxx_a" ] || {
    echo "FATAL: $libstdcxx_a not present in the toolchain" >&2
    exit 1
  }
  sed -i "s|[[:space:]]-lstdc++| $libstdcxx_a|g" Makefile
fi

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into snappy's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

so="$(find "$PBS_DEPS/__staging" -name snappy.so -type f | head -1)"
if [ -z "$so" ]; then
  echo "FATAL: snappy.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

# Both failure modes are silent at link time: a shared module may leave
# symbols undefined, so a missing C++ runtime only shows up at dlopen.
if [ "$linux" = 1 ]; then
  if readelf -d "$so" | grep -q 'libstdc++'; then
    echo "FATAL: snappy.so still links libstdc++ dynamically" >&2
    readelf -d "$so" >&2
    exit 1
  fi
  # Strong (U) references only: libstdc++.a's transactional-memory hooks
  # (_ZGTtnam, _ZGTtdlPv, …) are weak undefined by design and resolve to
  # null when libitm is absent, exactly as they do in bin/php.
  undef_cxx="$(nm -D --undefined-only "$so" | awk '$1 == "U" && $2 ~ /^_Z/ {print $2}')"
  if [ -n "$undef_cxx" ]; then
    echo "FATAL: snappy.so has unresolved C++ symbols:" >&2
    echo "$undef_cxx" >&2
    exit 1
  fi
fi

rel="${so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" snappy.so
echo "snappy OK ($rel)"
