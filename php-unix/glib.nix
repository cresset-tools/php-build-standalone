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
#
# Darwin specifics:
#   - libiconv: apple-sdk strips libiconv headers, so glib needs our
#     bundled GNU libiconv (same dep PHP itself consumes for ext/iconv).
#   - libresolv: nixpkgs's apple-sdk_14 omits the legacy BIND headers
#     (`<arpa/nameser.h>`, `<arpa/nameser_compat.h>`). glib 2.82's
#     gio/meson.build hard-requires C_IN from nameser.h. nixpkgs ships
#     these headers in `darwin.libresolv`'s `dev` output (the same
#     opensource libresolv-91 PHP uses for ext/standard/dns.c).
#   - proxy-libintl: glib's intl subproject uses wrap-git, which can't
#     run inside the Nix sandbox — pre-populated from a fetchurl tarball.
{ pkgs, mkDep, sources, libffi, pcre2, zlib, libiconv ? null, libresolv ? null }:
let
  inherit (pkgs) lib stdenv;
  proxyLibintlSrc = pkgs.fetchurl {
    inherit (sources.proxy-libintl) url sha256;
  };
in
mkDep {
  name = "glib";
  deps = [ libffi pcre2 zlib ]
    ++ lib.optionals stdenv.isDarwin [ libiconv ];
  extraEnv = lib.optionalAttrs stdenv.isDarwin {
    PBS_SRC_PROXY_LIBINTL = "${proxyLibintlSrc}";
    PBS_VER_PROXY_LIBINTL = sources.proxy-libintl.version;
    # darwin.libresolv's dev output ships <arpa/nameser.h> +
    # <arpa/nameser_compat.h> (apple-sdk omits these). It also ships
    # libresolv.dylib — gio links res_query() against it. The build-
    # time /nix/store install_name on the resulting libgio gets
    # rewritten to /usr/lib/libresolv.9.dylib at finalize time, same
    # pattern as build-php-post-install-darwin.sh.
    PBS_DEP_LIBRESOLV_INCLUDE = "${lib.getInclude libresolv}";
    PBS_DEP_LIBRESOLV_DIR     = "${libresolv}";
  };
}
