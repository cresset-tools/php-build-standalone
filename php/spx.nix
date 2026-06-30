# spx — php-spx, a sampling/tracing profiler with a built-in flame-graph
# web UI. Built via the just-installed bin/phpize, mirroring xdebug.nix and
# pcov.nix. SPX is the profiling sibling of xdebug's step-debugger and pcov's
# coverage driver: always-loadable, inert until activated (SPX_ENABLED=1 on
# the CLI, or the HTTP control panel for SAPI requests).
#
# Depends on `php` (for phpize/php-config/build files) and `zlib`. zlib is a
# COMPILE-TIME header dependency: SPX's config.m4 errors out ("spx support
# requires ZLIB") unless --with-zlib-dir points at a real zlib.h, which the
# Nix sandbox only has via this dep. The resulting spx.so does NOT carry a
# DT_NEEDED/RPATH on libz, though — SPX's config.m4 populates SPX_SHARED_LIBADD
# but never PHP_SUBSTs it, so `-lz` is dropped from the link and spx.so's gz*
# symbols stay undefined, resolved at dlopen against the libz.so.1 the
# interpreter already loads globally (bin/php has DT_NEEDED libz.so.1). This is
# exactly how SPX behaves on any stock PHP that links zlib, and it means spx
# adds no store path of its own: its per-ext manifest closure is empty.
#
# Source comes from GitHub (SPX is not published on PECL); the archive tarball
# extracts into php-spx-<version>/ (note the php- prefix), so build-spx.sh
# can't use the mkDep autotools template's default <name>-<version> subdir —
# it dispatches to the per-ext script instead.
#
# `spxSpec` is the value from sources.spxVersions.<series> — parallel to the
# xdebugSpec/pcovSpec pattern, kept separate so flake.nix can pair SPX
# releases with PHP variants independently.
{ mkDep, pkgs, php, zlib, spxSpec }:
mkDep {
  name = "spx";
  buildScript = ./build-spx.sh;
  version = spxSpec.version;
  src = pkgs.fetchurl { inherit (spxSpec) url sha256; };
  deps = [ php zlib ];
  # phpize needs autoconf + autoheader at build time (already in the toolchain
  # pkg list; listed here as defense-in-depth and to document the dependency
  # at the call site).
  extraInputs = with pkgs; [ autoconf automake libtool m4 ];
  # Web-UI relocation: build-spx.sh applies this patch so spx.http_ui_assets_dir
  # defaults (at MINIT) to the bundled web-UI assets resolved relative to
  # spx.so via dladdr — no php.ini changes needed. The assets themselves are
  # staged into $out/pbs-assets/web-ui and shipped by php/tarball-extension.nix
  # at share/php-spx/assets/web-ui inside the per-ext tarball.
  extraEnv = { PBS_SPX_RELOC_PATCH = ./spx-relocate-assets.patch; };
}
