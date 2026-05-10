#!/usr/bin/env bash
# Build GLib (libglib-2.0, libgobject-2.0, libgmodule-2.0, libgio-2.0,
# libgthread-2.0) into ${PBS_DEPS}.
#
# meson + ninja, in-tree (out-of-tree-build dir under sources/glib-<v>/).
# Auto-detected deps disabled aggressively — we only want libffi + pcre2
# + zlib pulled in (everything else is system-lib auto-detection that
# would leak nix-store paths into the final binary or pull in deps we
# don't bundle).

set -euo pipefail

: "${PBS_SRC_GLIB:?}"
: "${PBS_VER_GLIB:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_LIBFFI:?}"
: "${PBS_DEP_PCRE2:?}"
: "${PBS_DEP_ZLIB:?}"

src_dir="$PBS_SOURCES/glib-${PBS_VER_GLIB}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_GLIB" -C "$PBS_SOURCES"
cd "$src_dir"

# meson resolves libffi / pcre2 / zlib via pkg-config.
export PKG_CONFIG_PATH="$PBS_DEP_LIBFFI/lib/pkgconfig:$PBS_DEP_PCRE2/lib/pkgconfig:$PBS_DEP_ZLIB/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Meson's compile-only probes (-c) trip clang's
# -Werror=unused-command-line-argument because our CC wrapper has
# -Wl,-dynamic-linker / -Wl,-rpath baked in for the link step.
# -Qunused-arguments is clang's persistent silencer for that warning;
# unlike -Wno-error=..., its effect doesn't depend on flag ordering, so
# meson re-adding -Werror later in the command line can't undo it.
export CFLAGS="$CFLAGS -Qunused-arguments"
export CXXFLAGS="$CXXFLAGS -Qunused-arguments"

# NOTE: build-glib.sh is Linux-only right now. glib 2.82's
# gio/meson.build hard-requires <arpa/nameser.h> for its DNS resolver,
# and that header isn't shipped in nixpkgs's Darwin SDK closure
# (apple-sdk_14 omits the legacy BIND headers; libSystem-B doesn't
# carry them either). flake.nix only wires `libvips` and `vips` into
# the dep set on Linux; the Darwin matrix builds the same way as
# before this PR.
#
# If Darwin support is reintroduced later, additionally:
#   - export OBJC="$CC"           (objc add_languages probe by basename)
#   - export CFLAGS+=-DBIND_8_COMPAT=1 (Apple's nameser.h gates C_IN on it)
#   - patch glib gio to use its __BIONIC__ inline-defines fallback on
#     __APPLE__ as well, OR vendor arpa/nameser*.h headers.

build_dir="$src_dir/build"
rm -rf "$build_dir"

# NOTE: proxy-libintl handling for Darwin was removed alongside glib's
# Linux-only constraint — see comment block above. If reintroducing
# Darwin support, also re-add the subprojects/proxy-libintl/ unpack
# here, the source fetch in glib.nix, and the proxy-libintl entry in
# sources.nix.

# Nix sandbox has no /usr/bin/env; the helper python scripts under tools/
# carry "#!/usr/bin/env python3" shebangs. Rewrite to the absolute python3
# resolved from the toolchain's PATH. mkDep's dontFixup disables nixpkgs'
# patchShebangsAuto, so we do this by hand.
python3_abs="$(command -v python3)"
find "$src_dir" -type f \( -name '*.py' -o -name 'gen-*' \) -print0 \
  | xargs -0 sed -i "1s|^#!/usr/bin/env python3.*|#!${python3_abs}|"

# meson build: shared-only, no NLS, no docs/tests/introspection. selinux
# / libelf / xattr are explicitly disabled so meson's auto-detection
# can't quietly link us against host libs. systemtap / dtrace / sysprof
# are tracing-side tooling we don't ship.
meson_setup_status=0
meson setup "$build_dir" \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --default-library=shared \
  --buildtype=release \
  --auto-features=disabled \
  -Dtests=false \
  -Dnls=disabled \
  -Dintrospection=disabled \
  -Dglib_debug=disabled \
  -Dglib_assert=false \
  -Dglib_checks=true \
  -Dman-pages=disabled \
  -Ddocumentation=false \
  -Dselinux=disabled \
  -Dlibelf=disabled \
  -Dxattr=false \
  -Dsystemtap=disabled \
  -Ddtrace=disabled \
  -Dsysprof=disabled || meson_setup_status=$?

if [ "$meson_setup_status" -ne 0 ]; then
  echo
  echo "=== meson-log.txt (setup failed) ==="
  cat "$build_dir/meson-logs/meson-log.txt" || true
  exit "$meson_setup_status"
fi

ninja -C "$build_dir" -j"$NIX_BUILD_CORES"
ninja -C "$build_dir" install

# Strip share/ (locale skeletons, gettext machinery, gdb autoload
# scripts) — we disabled NLS so share/locale is empty, but glib still
# installs share/glib-2.0/{gdb,gettext,codegen,...}; gdb autoload
# scripts have absolute /nix/store python paths that would fail the
# text-leak gate. The codegen scripts under share/glib-2.0/codegen are
# kept (gdbus-codegen needs them), see below.
rm -rf "$PBS_DEPS/share/gdb"
rm -rf "$PBS_DEPS/share/gettext"
rm -rf "$PBS_DEPS/share/locale"
rm -rf "$PBS_DEPS/share/man"
rm -rf "$PBS_DEPS/share/bash-completion"

# Keep bin/ — libvips's meson invokes glib-mkenums during its build via
# pkg-config's glib_mkenums tool variable. The python shebang carries
# an absolute /nix/store path that would trip the finalize text-leak
# audit; finalize-common.sh's text-detox phase drops store/glib-*/bin/
# from the final tree post-merge so the runtime tarball stays clean.

for libname in libglib-2.0 libgobject-2.0 libgmodule-2.0 libgio-2.0 libgthread-2.0; do
  lib="$PBS_DEPS/lib/${libname}.${PBS_LIB_EXT}"
  [ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
  pbs_audit_lib "$lib" "$libname"
done
echo "glib OK"
