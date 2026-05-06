#!/usr/bin/env bash
# Build OpenSSL as a Mach-O dylib into ${PBS_DEPS}. Mirrors the Linux
# script but uses the darwin64-arm64-cc target.

set -euo pipefail

: "${PBS_SRC_OPENSSL:?}"
: "${PBS_VER_OPENSSL:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_ZLIB:?openssl needs zlib in its deps list}"

src_dir="$PBS_SOURCES/openssl-${PBS_VER_OPENSSL}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_OPENSSL" -C "$PBS_SOURCES"
cd "$src_dir"

# darwin64-arm64-cc emits Mach-O dylibs (libssl.3.dylib + libcrypto.3.dylib)
# with @rpath-relative install names. We rewrite to @rpath/<name> in
# finalize regardless, but starting from a sensible default avoids
# install_name_tool having to expand the load command.
perl Configure darwin64-arm64-cc \
  --prefix="$PBS_DEPS" \
  --openssldir=/etc/ssl \
  --libdir=lib \
  shared zlib no-tests no-docs no-engine \
  -I"$PBS_DEP_ZLIB/include" \
  -L"$PBS_DEP_ZLIB/lib"

make -j"$(getconf _NPROCESSORS_ONLN)"
make install_sw

rm -f "$PBS_DEPS/lib/libssl.a" "$PBS_DEPS/lib/libcrypto.a"
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/lib/ossl-modules"
rm -rf "$PBS_DEPS/etc"

for lib in libssl.dylib libcrypto.dylib; do
  if [ ! -L "$PBS_DEPS/lib/$lib" ] && [ ! -f "$PBS_DEPS/lib/$lib" ]; then
    echo "FATAL: $PBS_DEPS/lib/$lib not produced" >&2
    exit 1
  fi
done

echo "--- openssl LC_LOAD_DYLIB audit ---"
otool -L "$PBS_DEPS/lib/libssl.dylib" || true
echo "openssl OK"
