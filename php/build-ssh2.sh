#!/usr/bin/env bash
# Build ssh2.so/.dylib (the ssh2 PECL extension) against our just-built
# PHP and bundled libssh2. See php/ssh2.nix.
#
# Mirrors build-excimer.sh: phpize + configure + make + staged install,
# with the resulting .so copied into this dep's $out so
# tarball-extension.nix can package it as a separately addressable
# extension artifact.
#
# config.m4 does not use pkg-config: --with-ssh2=<prefix> is probed for
# include/libssh2.h, and -L<prefix>/lib comes from the same value. Without
# it config.m4 falls back to scanning /usr/local, /usr and /opt/homebrew,
# so always pass the bundled prefix explicitly. It also hard-requires
# libssh2 >= 1.9.0 and, on >= 1.11.0, enables ssh2_send_signal().

set -euo pipefail

: "${PBS_SRC_SSH2:?}"
: "${PBS_VER_SSH2:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?ssh2 needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_LIBSSH2:?ssh2 needs libssh2 headers + libs}"

src_dir="$PBS_SOURCES/ssh2-${PBS_VER_SSH2}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_SSH2" -C "$PBS_SOURCES"
cd "$src_dir"

"$PBS_DEP_PHP/bin/phpize"

./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --with-ssh2="$PBS_DEP_LIBSSH2"

# libssh2 >= 1.11.0 is pinned, so channel-signal support must be on.
# config.m4 only warns when the probe fails; turn that into a build error
# rather than silently shipping an ssh2.so without ssh2_send_signal().
grep -q '^#define PHP_SSH2_CHANNEL_SIGNAL 1' config.h \
  || { echo "FATAL: libssh2_channel_signal_ex probe failed" >&2; exit 1; }

make -j"$NIX_BUILD_CORES"

# Same staged-install dance as build-imagick.sh: php-config reports
# PHP's $out as extension_dir, but we install into ssh2's own $out.
make install INSTALL_ROOT="$PBS_DEPS/__staging"

ssh2_so="$(find "$PBS_DEPS/__staging" -name ssh2.so -type f | head -1)"
if [ -z "$ssh2_so" ]; then
  echo "FATAL: ssh2.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${ssh2_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$ssh2_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" ssh2.so
echo "ssh2 OK ($rel)"
