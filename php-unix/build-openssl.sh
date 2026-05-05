#!/usr/bin/env bash
# Build OpenSSL as a shared library into ${PBS_DEPS}, with zlib support.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh (sourced by the derivation).
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
# usual --build/--host triple). For our v1 single-target this is fine —
# linux-x86_64 is the right name on x86_64-linux.
#
# Notes on flag choice:
#   --libdir=lib     — without this, openssl uses lib64/ on 64-bit. The PBS
#                      tarball convention is single lib/, so override.
#   shared           — produces libssl.so.3 + libcrypto.so.3 (and the unversioned
#                      symlinks). We want shared.
#   no-tests         — saves 2 minutes; we don't run openssl's self-tests in
#                      the dep build.
#   no-docs          — saves another minute; PHP doesn't need openssl manpages.
#   zlib             — enables OPENSSL_NO_COMP=0; build the gzip-compression
#                      record-layer support. Most TLS deployments don't use
#                      it but PHP's openssl extension expects the symbol.
#   --prefix         — install root.
#   --openssldir     — runtime config dir (where openssl.cnf lives at runtime).
#                      Within the install tree so the tarball is self-contained.
# Invoke via `perl` rather than `./Configure` directly. Configure has
# `#! /usr/bin/env perl`, and Nix's build sandbox does NOT provide
# /usr/bin/env (nixpkgs's `patchShebangsAuto` would fix this, but it
# only runs on the unpackPhase output, and we extract manually). Going
# through perl sidesteps the whole shebang dance.
#
# OPENSSLDIR notes: openssl bakes this path into libcrypto.so.3 for
# locating openssl.cnf at runtime. We set it to /etc/ssl (Debian/Ubuntu
# convention) so the .so doesn't carry a /nix/store reference and the
# tarball uses whatever openssl.cnf exists on the host system. PHP code
# rarely loads openssl.cnf explicitly; when it does, OPENSSL_CONF env or
# the openssl.cafile ini directive override anyway.
#
# Engine support is deprecated since OpenSSL 3.0 (replaced by providers);
# PHP's openssl ext doesn't use engines. `no-engine` removes the codepath
# AND avoids burning ENGINESDIR=$prefix/lib/engines-3 into libcrypto.
perl Configure linux-x86_64 \
  --prefix="$PBS_DEPS" \
  --openssldir=/etc/ssl \
  --libdir=lib \
  shared zlib no-tests no-docs no-engine \
  -I"$PBS_DEP_ZLIB/include" \
  -L"$PBS_DEP_ZLIB/lib"

make -j"$(nproc)"
make install_sw

# Trim the install to just what PHP needs:
#   - shared libs (libssl.so.3, libcrypto.so.3) — yes
#   - headers (include/openssl/*.h) — yes (PHP build needs them)
#   - .pc files (lib/pkgconfig/*) — yes (php-config / pecl rely on them)
#   - libssl.a / libcrypto.a — NO (static archives we don't ship)
#   - bin/openssl, bin/c_rehash — NO (CLI tools, PHP doesn't need them
#     and they bake $prefix paths)
#   - lib/ossl-modules/* — NO (optional FIPS/legacy providers; PHP's
#     openssl ext loads only the default provider which is built into
#     libcrypto.so.3 itself)
rm -f "$PBS_DEPS/lib/libssl.a" "$PBS_DEPS/lib/libcrypto.a"
rm -rf "$PBS_DEPS/bin"
rm -rf "$PBS_DEPS/lib/ossl-modules"
# c_rehash also gets installed under /etc/ssl/misc — not a /nix path
# leak source itself but unneeded.
rm -rf "$PBS_DEPS/etc"

# Sanity: shared libs must exist.
for lib in libssl.so libcrypto.so; do
  if [ ! -L "$PBS_DEPS/lib/$lib" ] && [ ! -f "$PBS_DEPS/lib/$lib" ]; then
    echo "FATAL: $PBS_DEPS/lib/$lib not produced" >&2
    exit 1
  fi
done

# Sanity: NEEDED list should reference libz by soname (libz.so.1), NOT by
# the /nix/store/...-pbs-zlib path. If linker baked an absolute path,
# something's wrong with our toolchain seal — fail now, before tree merge.
echo
echo "--- openssl NEEDED audit ---"
needed_libssl=$(readelf -d "$(readlink -f "$PBS_DEPS/lib/libssl.so")" | grep NEEDED || true)
echo "libssl: $needed_libssl"
if echo "$needed_libssl" | grep -q '/nix/store'; then
  echo "FATAL: libssl has a /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "openssl OK"
