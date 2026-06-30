#!/usr/bin/env bash
# Build spx.so/.dylib (the php-spx profiler) against our just-built PHP and
# bundled zlib. Mirrors build-xdebug.sh: phpize + configure + make + staged
# install, with the resulting .so copied into this dep's $out so
# tarball-extension.nix can package it as a separately addressable artifact.
#
# spx loads as a regular `extension=spx` (STANDARD_MODULE_HEADER, NOT a
# zend_extension — its get_module() doesn't export the zend_extension entry
# point), so the per-ext tarball tags it like pcov, not xdebug.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh); mkDep exports
# PBS_DEP_PHP / PBS_DEP_ZLIB pointing at those derivations' $out.

set -euo pipefail

: "${PBS_SRC_SPX:?}"
: "${PBS_VER_SPX:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_PHP:?spx needs the PHP derivation for phpize/php-config}"
: "${PBS_DEP_ZLIB:?spx config.m4 needs zlib.h via --with-zlib-dir}"

# GitHub archive tarballs extract into php-spx-<version>/, not spx-<version>/.
src_dir="$PBS_SOURCES/php-spx-${PBS_VER_SPX}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_SPX" -C "$PBS_SOURCES"
cd "$src_dir"

# Darwin: SPX's config.m4 appends `-Werror` to CFLAGS *after* our env CFLAGS
# (config.m4: `CFLAGS="$CFLAGS -Werror …"`). Our Darwin clang wrapper injects
# `-Wl,-headerpad_max_install_names` into every invocation including `-c`
# compile steps, which emits a spurious
# `-Wunused-command-line-argument` warning that -Werror promotes to a fatal
# error. Because SPX's -Werror lands after ours, the order-dependent
# `-Wno-error=unused-command-line-argument` would be undone; `-Qunused-arguments`
# silences the warning's *emission* entirely, so a later -Werror has nothing
# to promote (same rationale as shared/build-glib.sh). Linux's clang wrapper
# already bakes in -Wno-unused-command-line-argument, so this is Darwin-only.
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  export CFLAGS="$CFLAGS -Qunused-arguments"
fi

"$PBS_DEP_PHP/bin/phpize"

# --with-spx-assets-dir overrides config.m4's `$prefix/share/misc/php-spx/assets`
# default. Left unset, $prefix resolves to PBS_DEP_PHP's /nix/store path, which
# would bake that build-time store path into spx.so as the compile-time
# SPX_HTTP_UI_ASSETS_DIR constant — a build-path leak that also wouldn't exist
# on a consumer machine. We ship spx.so only (the web-UI flame-graph assets are
# out of scope for the single-.so per-ext tarball format), so we bake SPX's
# conventional documented default instead; users who want the web UI install
# the assets themselves and point spx.http_ui_assets_dir at them (it's a
# PHP_INI_SYSTEM OnUpdateString override of this default).
# --with-zlib-dir points config.m4 at our bundled zlib.h (it errors without a
# findable zlib header). This is compile-time only: SPX never PHP_SUBSTs its
# SPX_SHARED_LIBADD, so the link drops -lz and spx.so's gz* symbols resolve at
# dlopen against the interpreter's already-loaded libz.so.1 (see spx.nix).
./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-spx \
  --with-zlib-dir="$PBS_DEP_ZLIB" \
  --with-spx-assets-dir=/usr/local/share/misc/php-spx/assets

make -j"$NIX_BUILD_CORES"

# Staged-install dance (see build-xdebug.sh): php-config reports PHP's $out as
# extension_dir, but we install into spx's own $out. SPX's Makefile.frag also
# redefines `install:` to copy assets/web-ui into INSTALL_ROOT — harmless here
# (it lands under __staging and is discarded; we only lift spx.so out).
make install INSTALL_ROOT="$PBS_DEPS/__staging"

spx_so="$(find "$PBS_DEPS/__staging" -name spx.so -type f | head -1)"
if [ -z "$spx_so" ]; then
  echo "FATAL: spx.so not produced under $PBS_DEPS/__staging" >&2
  find "$PBS_DEPS/__staging" -type f >&2
  exit 1
fi

rel="${spx_so#$PBS_DEPS/__staging}"
rel="${rel#$PBS_DEP_PHP}"

mkdir -p "$PBS_DEPS$(dirname "$rel")"
cp "$spx_so" "$PBS_DEPS$rel"
rm -rf "$PBS_DEPS/__staging"

pbs_audit_lib "$PBS_DEPS$rel" spx.so
echo "spx OK ($rel)"
