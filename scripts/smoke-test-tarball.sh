#!/usr/bin/env bash
# Smoke-test a php-*.tar.zst artifact.
#
# Usage: smoke-test-tarball.sh <tarball-path> [expected-major.minor]
#
# Inputs:
#   $1  path to php-*.tar.zst
#   $2  (optional) expected PHP major.minor, e.g. "8.3"
#
# Checks: extraction, php -v, version match, php -m, static-build
# functional probes (sodium → libsodium, libxml → libxml2, openssl
# → openssl), relocation (move install/ → relocated/, verify
# extension_dir tracks).
#
# The interpreter tarball is Debian-aligned (REFACTOR_DEBIAN_ALIGNED.md):
# zero .so files ship — every extension travels via its own per-ext
# tarball. The probes here only exercise modules statically linked
# into bin/php (sodium, libxml, openssl, etc. — the Debian php8.2-cli
# static set). The per-ext load gate lives in tests/smoke.sh.
#
# Outputs: grouped progress to stdout; exits non-zero on any failure.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <tarball-path> [expected-major.minor]" >&2
  exit 1
fi

TARBALL="$1"
EXPECTED_VERSION="${2:-}"

# Canonicalize the temp path: macOS /tmp is a symlink to /private/tmp, and
# pbs_relocate's _NSGetExecutablePath path is realpath'd, so the prefix
# match in the relocation gate below would otherwise miss.
smoke_root="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$smoke_root"' EXIT

echo "::group::extract $TARBALL"
tar --use-compress-program=unzstd -xf "$TARBALL" -C "$smoke_root"
echo "::endgroup::"

PHP="$smoke_root/install/bin/php"

echo "::group::php -v"
"$PHP" -v
echo "::endgroup::"

if [ -n "$EXPECTED_VERSION" ]; then
  actual=$("$PHP" -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION;')
  if [ "$actual" != "$EXPECTED_VERSION" ]; then
    echo "FAIL: expected PHP $EXPECTED_VERSION, got $actual" >&2
    exit 1
  fi
  echo "version check: ok ($actual)"
fi

echo "::group::php -m"
"$PHP" -m
echo "::endgroup::"

echo "::group::static-build functional probes"
# sodium → exercises bundled libsodium end-to-end (key generation +
# detached signature verify). libxml → exercises bundled libxml2
# through the static libxml binding that PHP links into bin/php
# (no dom.so needed; libxml_use_internal_errors is in core).
# openssl_random_pseudo_bytes → exercises bundled openssl. Each
# probe loads a different bundled C-lib, so a regression in any
# one shows up here as a load or runtime failure.
# shellcheck disable=SC2016  # PHP code, intentionally not shell-expanded
"$PHP" -r '
  $kp = sodium_crypto_sign_keypair();
  $sk = sodium_crypto_sign_secretkey($kp);
  $pk = sodium_crypto_sign_publickey($kp);
  $sig = sodium_crypto_sign_detached("hello", $sk);
  if (!sodium_crypto_sign_verify_detached($sig, "hello", $pk)) {
    fwrite(STDERR, "FAIL: sodium signature did not verify\n"); exit(1);
  }
  echo "sodium: ok\n";

  // libxml is built static into bin/php (no .so); these procedural
  // functions exercise the bundled libxml2 store path without needing
  // dom.so (which is now per-ext).
  libxml_use_internal_errors(true);
  if (libxml_use_internal_errors() !== true) {
    fwrite(STDERR, "FAIL: libxml_use_internal_errors did not stick\n"); exit(1);
  }
  libxml_clear_errors();
  if (libxml_get_errors() !== []) {
    fwrite(STDERR, "FAIL: libxml_clear_errors did not empty the queue\n"); exit(1);
  }
  echo "libxml: ok\n";

  $bytes = openssl_random_pseudo_bytes(16, $strong);
  if (strlen($bytes) !== 16 || !$strong) {
    fwrite(STDERR, "FAIL: openssl_random_pseudo_bytes did not return 16 strong bytes\n"); exit(1);
  }
  echo "openssl: ok\n";
'
echo "::endgroup::"

echo "::group::expect relocation tracks the running binary"
mv "$smoke_root/install" "$smoke_root/relocated"
ext_dir=$("$smoke_root/relocated/bin/php" -r 'echo ini_get("extension_dir");')
case "$ext_dir" in
  "$smoke_root/relocated/lib/extensions/"*) echo "ok: $ext_dir" ;;
  *) echo "FAIL: extension_dir=$ext_dir did not track relocation" >&2; exit 1 ;;
esac
echo "::endgroup::"
