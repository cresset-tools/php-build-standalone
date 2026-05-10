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
{ mkDep, libffi, pcre2, zlib }:
mkDep {
  name = "glib";
  deps = [ libffi pcre2 zlib ];
}
