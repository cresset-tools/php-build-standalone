# GLib bundled-dep derivation. Provides libglib-2.0, libgobject-2.0,
# libgmodule-2.0, libgio-2.0, libgthread-2.0 — required by libvips.
#
# First meson-based dep we ship; build-glib.sh handles meson setup +
# ninja invocation rather than the autotools template. Deps:
#   - libffi: GObject's GClosure marshalling
#   - pcre2:  GRegex (since glib 2.74, no in-tree copy)
#   - zlib:   GResource compression / GIO file streams
#
# NLS is disabled (no .mo translations shipped). Tests, docs, GTK-doc,
# manpages, gtester, gobject-introspection, dtrace, sysprof — all off.
# We keep glib-mkenums / glib-genmarshal / gdbus-codegen in bin/ because
# downstream consumers (libvips, glib-using PECL exts) call them at
# build time; finalize-common.sh detoxes their /nix/store leaks.
{ pkgs, mkDep, sources, libffi, pcre2, zlib, libiconv ? null }:
let
  inherit (pkgs) lib stdenv;
  # Darwin-only: pre-fetch proxy-libintl source. build-glib.sh extracts
  # it into subprojects/proxy-libintl/ before invoking meson, replacing
  # the wrap-git fetch that fails in the network-isolated sandbox.
  proxyLibintlSrc = pkgs.fetchurl {
    inherit (sources.proxy-libintl) url sha256;
  };
in
mkDep {
  name = "glib";
  # libiconv is Darwin-only. On Linux glibc provides iconv directly and
  # glib's meson finds the `builtin` libc iconv; on Darwin apple-sdk
  # strips libiconv headers from the SDK, so we feed glib our bundled
  # GNU libiconv (the same dep PHP itself consumes for ext/iconv).
  deps = [ libffi pcre2 zlib ]
    ++ lib.optionals stdenv.isDarwin [ libiconv ];
  extraEnv = lib.optionalAttrs stdenv.isDarwin {
    PBS_SRC_PROXY_LIBINTL = "${proxyLibintlSrc}";
    PBS_VER_PROXY_LIBINTL = sources.proxy-libintl.version;
  };
}
