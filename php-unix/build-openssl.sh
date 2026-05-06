#!/usr/bin/env bash
# Build OpenSSL as a shared library into ${PBS_DEPS}, with zlib support.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh).
# Inherits PBS_DEP_ZLIB pointing at the zlib derivation's $out.

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

# OpenSSL's Configure is a perl script that takes a target name (not the
# usual --build/--host triple). Pick the right target per platform —
# linux-x86_64 emits ELF .so, darwin64-arm64-cc emits Mach-O dylibs with
# @rpath-relative install names (we rewrite to @rpath/<name> in finalize
# regardless, but starting from a sensible default avoids extra
# install_name_tool work).
#
# Notes on flag choice:
#   --libdir=lib     — without this, openssl uses lib64/ on 64-bit. The PBS
#                      tarball convention is single lib/, so override.
#   shared           — produces libssl.<ext>.3 + libcrypto.<ext>.3.
#   no-tests / no-docs — saves build time; not shipped.
#   zlib             — enables OPENSSL_NO_COMP=0; PHP's openssl extension
#                      expects the symbol.
#   --openssldir     — runtime config dir. /etc/ssl is the Debian/Ubuntu
#                      convention; macOS doesn't have it but OPENSSL_CONF
#                      env or php.ini openssl.cafile override anyway.
#   no-engine        — engines are deprecated since OpenSSL 3.0 (replaced
#                      by providers); PHP's openssl ext doesn't use them.
# Invoke via `perl` rather than `./Configure` directly so we don't depend
# on /usr/bin/env in the build sandbox.
case "$OSTYPE" in
  darwin*) openssl_target=darwin64-arm64-cc ;;
  *)       openssl_target=linux-x86_64 ;;
esac

perl Configure "$openssl_target" \
  --prefix="$PBS_DEPS" \
  --openssldir=/etc/ssl \
  --libdir=lib \
  shared zlib no-tests no-docs no-engine \
  -I"$PBS_DEP_ZLIB/include" \
  -L"$PBS_DEP_ZLIB/lib"

make -j"$PBS_NPROC"
make install_sw

# Trim the install:
#   - .a archives we don't ship
#   - bin/openssl, bin/c_rehash CLI tools
#   - lib/ossl-modules/* optional providers (PHP only loads default)
#   - /etc/ssl/misc helper scripts
rm -f "$PBS_DEPS/lib/libssl.a" "$PBS_DEPS/lib/libcrypto.a"
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/lib/ossl-modules"
rm -rf "$PBS_DEPS/etc"

# Sanity: shared libs must exist.
for libname in libssl libcrypto; do
  lib="$PBS_DEPS/lib/${libname}.${PBS_LIB_EXT}"
  if [ ! -L "$lib" ] && [ ! -f "$lib" ]; then
    echo "FATAL: $lib not produced" >&2
    exit 1
  fi
done

pbs_audit_lib "$PBS_DEPS/lib/libssl.${PBS_LIB_EXT}" libssl
echo "openssl OK"
