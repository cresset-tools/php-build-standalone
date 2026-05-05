#!/usr/bin/env bash
# Build libsodium as a shared library into ${PBS_DEPS}.
# PHP's sodium extension links against libsodium.so for modern crypto
# primitives (Ed25519, X25519, ChaCha20-Poly1305, BLAKE2b, etc.).
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh. No other deps.

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

make -j"$(nproc)"
make install

# Sanity: shared lib must exist with a clean NEEDED list (no /nix/store
# leakage).
lib="$PBS_DEPS/lib/libsodium.so"
real_lib="$(readlink -f "$lib")"
echo
echo "--- libsodium NEEDED audit ---"
needed=$(readelf -d "$real_lib" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: libsodium has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "libsodium OK"
