#!/usr/bin/env bash
# Build ncurses (libncursesw + libtinfow) as shared libraries into ${PBS_DEPS}.
#
# libedit needs a terminfo backend. We bundle ncurses rather than link
# against a host libtinfo because the host library's .so version differs
# between distros (libtinfo.so.5 on older systems, .so.6 on newer ones),
# making host linkage non-portable.
#
# We enable wide-char (--enable-widec) so libedit gets the full Unicode
# line-editing UX. The widec variant installs as libncursesw / libtinfow;
# libedit's configure probes for both the widec and non-widec names so it
# will find them.
#
# --with-fallbacks=... compiles a small set of common terminal definitions
# directly into libtinfow so the library works even on containers that have
# no /usr/share/terminfo. The full terminfo database (~7 MB) is NOT shipped.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh).

set -euo pipefail

: "${PBS_SRC_NCURSES:?}"
: "${PBS_VER_NCURSES:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

src_dir="$PBS_SOURCES/ncurses-${PBS_VER_NCURSES}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_NCURSES" -C "$PBS_SOURCES"
cd "$src_dir"

# Configure flags rationale:
#   --with-shared             — build shared libs (libncursesw.so/.dylib,
#                               libtinfow.so/.dylib).
#   --without-debug           — no *_g debug variants; reduces output size.
#   --without-ada             — no Ada95 bindings; we have no Ada in the stack.
#   --without-tests           — skip the test programs; saves build time.
#   --without-cxx-binding     — no C++ ncurses++ library; avoids libstdc++
#                               entanglement.
#   --enable-widec            — wide-char (Unicode) variant; installs as
#                               libncursesw / libtinfow. libedit's configure
#                               prefers widec when available.
#   --with-termlib            — split libtinfo out from libncurses; matches
#                               what most distros ship and what libedit
#                               links against.
#   --enable-pc-files         — install .pc files so libedit's configure
#                               (and our PKG_CONFIG_PATH wiring) can find
#                               ncurses.
#   --with-pkg-config-libdir  — put the .pc files in our $PBS_DEPS/lib/pkgconfig.
#   --with-default-terminfo-dir / --with-terminfo-dirs
#                             — tell the runtime where to look for the
#                               host's terminfo db.
#   --with-fallbacks          — compile these common terminal defs directly
#                               into libtinfow so basic terminal support
#                               works with no host terminfo at all.
#   --disable-static          — shared only.
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --with-shared \
  --without-debug \
  --without-ada \
  --without-tests \
  --without-cxx-binding \
  --enable-widec \
  --with-termlib \
  --enable-pc-files \
  "--with-pkg-config-libdir=$PBS_DEPS/lib/pkgconfig" \
  "--with-default-terminfo-dir=/etc/terminfo:/lib/terminfo:/usr/share/terminfo" \
  "--with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo" \
  "--with-fallbacks=linux,xterm,xterm-256color,vt100,screen,tmux"

make -j"$NIX_BUILD_CORES"

# `make install` in the misc/ subdir tries to run tic (the terminfo
# compiler) to build the full terminfo database and write it to the paths
# listed in --with-default-terminfo-dir (e.g. /etc/terminfo). Those paths
# are host system paths that don't exist in the Nix sandbox. Redirect the
# terminfo install via ticdir override and discard the output — the
# fallback definitions compiled into libtinfow are sufficient.
terminfo_tmp="$PBS_DEPS/share/terminfo-install-tmp"
mkdir -p "$terminfo_tmp"
make install "ticdir=$terminfo_tmp"
rm -rf "$terminfo_tmp"

# Drop ncurses's bin/, .a archives, and ~957 man pages.
rm -rf "$PBS_DEPS/bin"
rm -f "$PBS_DEPS/lib"/lib*.a
rm -rf "$PBS_DEPS/share/man"
rm -rf "$PBS_DEPS/share/tabset"

# Compat symlinks so libedit's configure finds the widec libs under
# their unsuffixed names. Soversioning convention differs by platform
# (Linux: libfoo.so.<major>; Darwin: libfoo.<major>.dylib), so the
# right snippet is selected on the Nix side and threaded in via
# $PBS_NCURSES_SYMLINKS.
: "${PBS_NCURSES_SYMLINKS:?set by ncurses.nix}"
source "$PBS_NCURSES_SYMLINKS"

# Header compat: ncurses --enable-widec installs headers under include/ncursesw/
# but libedit looks in include/ directly for ncurses.h / curses.h / termcap.h.
for hdr in ncurses.h curses.h termcap.h; do
  if [ -f "$PBS_DEPS/include/ncursesw/$hdr" ]; then
    ln -sf "ncursesw/$hdr" "$PBS_DEPS/include/$hdr"
  fi
done

for libname in libtinfow libncursesw; do
  libfile="$PBS_DEPS/lib/${libname}.${PBS_LIB_EXT}"
  [ -e "$libfile" ] || { echo "FATAL: $libfile not produced" >&2; exit 1; }
  pbs_audit_lib "$libfile" "ncurses ${libname}"
done
echo "ncurses OK"
