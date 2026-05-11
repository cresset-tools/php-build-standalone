# vips — PECL extension binding libvips's C API to PHP. Built via the
# just-installed bin/phpize, mirroring xdebug.nix and imagick.nix.
#
# Depends on `php` (for phpize/php-config/build files) and `libvips`
# (which transitively brings glib + the bundled image format delegates).
# The configure script consumes `vips.pc` from libvips's pkg-config
# tree.
{ mkDep, pkgs, php, libvips, glib, vipsSpec }:
mkDep {
  name = "vips";
  buildScript = ./build-vips.sh;
  version = vipsSpec.version;
  src = pkgs.fetchurl { inherit (vipsSpec) url sha256; };
  # glib appears here in addition to libvips because vips.pc has
  # Requires: glib-2.0 gobject-2.0 gio-2.0 — pkg-config follows the
  # chain only if those .pc files are reachable via PKG_CONFIG_PATH,
  # so we need glib's prefix exported as PBS_DEP_GLIB.
  deps = [ php libvips glib ];
  extraInputs = with pkgs; [ autoconf automake libtool m4 pkg-config ];
}
