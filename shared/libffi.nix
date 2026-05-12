# libffi bundled-dep derivation. Provides libffi.so/.dylib + headers for
# glib (GObject closures use libffi to invoke C callbacks across signal
# emissions and GClosure marshalling) and transitively for libvips.
#
# Tarball quirk: libffi 3.4.x installs headers under
# include/ffi-<arch>/<arch>-…/ rather than directly under include/. We
# leave that alone — pkg-config files (libffi.pc) point at the correct
# include subdir, and glib's meson uses pkg-config exclusively. bin/ is
# empty (libffi has no CLI).
{ mkDep }:
mkDep {
  name = "libffi";
  builder = "autotools";
  configureFlags = [
    # Don't install version-numbered include subdir: libffi 3.4.x default
    # is to put headers under include/, but it also drops a couple of
    # headers under lib/libffi-<v>/include/ — disable that for cleanliness.
    "--disable-multi-os-directory"
    "--disable-docs"
  ];
  auditLibs = [ "libffi" ];
}
