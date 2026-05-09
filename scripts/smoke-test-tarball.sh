#!/usr/bin/env bash
# Smoke-test a php-*.tar.zst artifact.
#
# Usage: smoke-test-tarball.sh <tarball-path> [expected-major.minor]
#
# Inputs:
#   $1  path to php-*.tar.zst
#   $2  (optional) expected PHP major.minor, e.g. "8.3"
#
# Checks: extraction, php -v, version match, php -m, intl currency probe,
# relocation (move install/ → relocated/, verify extension_dir tracks).
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

echo "::group::expect intl currency formatting"
"$PHP" -r 'echo NumberFormatter::create("en_US", NumberFormatter::CURRENCY)->formatCurrency(1234.56, "USD"), "\n";'
echo "::endgroup::"

echo "::group::expect relocation tracks the running binary"
mv "$smoke_root/install" "$smoke_root/relocated"
ext_dir=$("$smoke_root/relocated/bin/php" -r 'echo ini_get("extension_dir");')
case "$ext_dir" in
  "$smoke_root/relocated/lib/extensions/"*) echo "ok: $ext_dir" ;;
  *) echo "FAIL: extension_dir=$ext_dir did not track relocation" >&2; exit 1 ;;
esac
echo "::endgroup::"
