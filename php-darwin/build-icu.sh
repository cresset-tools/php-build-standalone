#!/usr/bin/env bash
# Build ICU as Mach-O dylibs into ${PBS_DEPS}.
#
# Unlike the Linux side, we do NOT static-link the C++ runtime: macOS's
# /usr/lib/libc++.1.dylib is ABI-stable across system versions (back to
# Mavericks), so dynamic linking against it is portable. Saves ~3 MB
# and avoids the static-libc++ build-system gymnastics.

set -euo pipefail

: "${PBS_SRC_ICU:?}"
: "${PBS_VER_ICU:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_root="$PBS_SOURCES/icu-${PBS_VER_ICU}"
rm -rf "$src_root"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ICU" -C "$PBS_SOURCES"
mv "$PBS_SOURCES/icu" "$src_root"
cd "$src_root/source"

./runConfigureICU MacOSX \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --disable-tests \
  --disable-samples \
  --disable-extras

make -j"$(getconf _NPROCESSORS_ONLN)"
make install

rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/sbin"
rm -rf "$PBS_DEPS/lib/icu"
rm -rf "$PBS_DEPS/share/icu"

echo "--- ICU LC_LOAD_DYLIB audit ---"
for libname in libicuuc libicui18n libicudata libicuio; do
  lib="$PBS_DEPS/lib/${libname}.dylib"
  if [ ! -e "$lib" ]; then
    echo "FATAL: missing $lib" >&2
    exit 1
  fi
  echo "# ${libname}:"
  otool -L "$lib" || true
done
echo "ICU OK"
