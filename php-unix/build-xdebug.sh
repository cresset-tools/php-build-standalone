#!/usr/bin/env bash
# Build xdebug.so as a Zend extension against our just-built PHP.
#
# This is the end-to-end cross-check of the phpize / php-config relocation
# patches: phpize is invoked from $PBS_DEP_PHP/bin/phpize and must (a)
# correctly resolve $prefix from $0 → $PBS_DEP_PHP, and (b) emit
# build-files referencing $prefix/lib/php/build, not the build-time path.
# If either patch broke, this build dies.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh; mkDep.nix exports
# PBS_DEP_PHP pointing at the PHP derivation's $out.

set -euo pipefail

: "${PBS_SRC_XDEBUG:?}"
: "${PBS_VER_XDEBUG:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?xdebug needs the PHP derivation for phpize/php-config}"

src_dir="$PBS_SOURCES/xdebug-${PBS_VER_XDEBUG}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_XDEBUG" -C "$PBS_SOURCES"
cd "$src_dir"

# phpize copies build files (php.m4, libtool.m4, gen_stub.php, etc.) from
# $PBS_DEP_PHP/lib/php/build/ into ./build/, generates configure.ac from
# scripts/phpize.m4, and runs autoconf+autoheader to produce ./configure.
"$PBS_DEP_PHP/bin/phpize"

# Configure xdebug as a shared Zend extension. --with-php-config tells
# configure where to find php-config (which reports include paths,
# extension_dir, ABI numbers, etc.) so the resulting xdebug.so links
# against the matching ABI.
./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config"

make -j"$(nproc)"

# `make install` puts xdebug.so into php-config's reported extension_dir.
# At this stage php-config returns the build-time PBS_DEP_PHP-rooted path
# (e.g. /nix/store/<hash>-pbs-php-8.4.3/lib/extensions/no-debug-non-zts-XXX),
# but our PBS_DEPS for THIS derivation is xdebug's own /nix/store/<hash>-pbs-xdebug-...
# We can't let make install write into PHP's $out (read-only), so we use
# INSTALL_ROOT to redirect the install root, then move the file under our
# own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

# Walk the staging tree to find xdebug.so (path is sapi-version-dependent).
xdebug_so="$(find "$PBS_DEPS/__staging" -name xdebug.so -type f | head -1)"
if [ -z "$xdebug_so" ]; then
  echo "FATAL: xdebug.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

# Strip the staging prefix and PBS_DEP_PHP prefix to get the relative path
# under <prefix>/lib/extensions/... so we install it at the corresponding
# location under our own $out. tree.nix's lib/ merge will combine it with
# PHP's tree at the canonical extensions/ path.
rel="${xdebug_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$xdebug_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

# Sanity: NEEDED list should not contain /nix/store paths.
echo
echo "--- xdebug.so NEEDED audit ---"
needed=$(readelf -d "$PBS_DEPS$rel" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: xdebug.so has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "xdebug OK ($rel)"
