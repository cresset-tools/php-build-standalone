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
: "${PBS_SPX_RELOC_PATCH:?web-ui asset relocation patch (php/spx-relocate-assets.patch)}"

# GitHub archive tarballs extract into php-spx-<version>/, not spx-<version>/.
src_dir="$PBS_SOURCES/php-spx-${PBS_VER_SPX}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_SPX" -C "$PBS_SOURCES"
cd "$src_dir"

# PBS: relocate spx.http_ui_assets_dir to the bundled web-UI assets at
# runtime (resolved relative to spx.so via dladdr), so the HTTP flame-graph
# UI works with no php.ini changes wherever the per-ext tarball is unpacked.
# See php/spx-relocate-assets.patch for the full rationale. --fuzz=2 -p1
# mirrors prepare-php.sh's PATCH_OPTS.
patch --fuzz=2 -p1 < "$PBS_SPX_RELOC_PATCH"

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

# --with-spx-assets-dir sets the compile-time SPX_HTTP_UI_ASSETS_DIR constant
# (config.m4 appends "/web-ui"). It's only the FALLBACK now: the
# spx-relocate-assets patch overrides spx.http_ui_assets_dir at MINIT to the
# bundled assets resolved relative to spx.so, so the web UI works with no
# php.ini changes. We pass a stable absolute value (NOT $prefix, which would
# bake PBS_DEP_PHP's /nix/store path into the .so) purely as that fallback —
# the runtime override is what actually fires. The matching assets tree ships
# in the per-ext tarball (see the pbs-assets copy below + tarball-extension.nix).
# --with-zlib-dir points config.m4 at our bundled zlib.h (it errors without a
# findable zlib header). This is compile-time only: SPX never PHP_SUBSTs its
# SPX_SHARED_LIBADD, so the link drops -lz and spx.so's gz* symbols resolve at
# dlopen against the interpreter's already-loaded libz.so.1 (see spx.nix).
./configure \
  --with-php-config="$PBS_DEP_PHP/bin/php-config" \
  --enable-spx \
  --with-zlib-dir="$PBS_DEP_ZLIB" \
  --with-spx-assets-dir=/usr/local/share/php-spx/assets

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

# PBS: ship the web-UI assets in this dep's $out under a NON-merged subdir
# (pbs-assets/). tree.nix only merges lib/include/bin/sbin/share/etc from
# interpreter deps into the install root, so pbs-assets/ stays out of the
# interpreter tarball; php/tarball-extension.nix lifts it into the spx
# per-ext tarball at share/php-spx/assets/web-ui. The spx-relocate-assets
# patch makes spx.so resolve exactly that path at runtime (relative to its
# own location), so the HTTP UI is served straight from the unpacked
# per-ext tarball with no extra setup.
mkdir -p "$PBS_DEPS/pbs-assets"
cp -a "$src_dir/assets/web-ui" "$PBS_DEPS/pbs-assets/web-ui"

pbs_audit_lib "$PBS_DEPS$rel" spx.so
echo "spx OK ($rel, +web-ui assets)"
