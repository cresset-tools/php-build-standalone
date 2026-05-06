#!/usr/bin/env bash
# Build libsodium as a shared library into ${PBS_DEPS}.
# PHP's sodium extension links against libsodium for modern crypto
# primitives (Ed25519, X25519, ChaCha20-Poly1305, BLAKE2b, etc.).
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh). No deps.

set -euo pipefail

: "${PBS_SRC_LIBSODIUM:?}"
: "${PBS_VER_LIBSODIUM:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/libsodium-${PBS_VER_LIBSODIUM}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBSODIUM" -C "$PBS_SOURCES"
cd "$src_dir"

# Configure flags rationale:
#   --disable-static / --enable-shared — shared-only, matches the rest of
#                                        the bundled deps.
#   (No --enable-minimal — PHP's sodium extension uses the full API
#   including crypto_pwhash, crypto_box_seal, etc., which minimal drops.)
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$NIX_BUILD_CORES"
make install

lib="$PBS_DEPS/lib/libsodium.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libsodium
echo "libsodium OK"
