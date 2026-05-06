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
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh.

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
#   --with-shared             — build shared libs (libncursesw.so, libtinfow.so)
#   --without-debug           — no *_g debug variants; reduces output size.
#   --without-ada             — no Ada95 bindings; we have no Ada in the stack.
#   --without-tests           — skip the test programs; saves build time.
#   --without-cxx-binding     — no C++ ncurses++ library; avoids libstdc++
#                               entanglement (we static-link C++ elsewhere but
#                               it's cleaner not to drag it in here at all).
#   --enable-widec            — wide-char (Unicode) variant; installs as
#                               libncursesw / libtinfow. libedit's configure
#                               prefers widec when available.
#   --with-termlib            — split libtinfo out from libncurses; matches what
#                               most distros ship and what libedit links against.
#   --enable-pc-files         — install .pc files so libedit's configure (and
#                               our PKG_CONFIG_PATH wiring) can find ncurses.
#   --with-pkg-config-libdir  — put the .pc files in our $PBS_DEPS/lib/pkgconfig
#                               tree, not in an ncurses-specific path.
#   --with-default-terminfo-dir / --with-terminfo-dirs
#                             — tell the runtime where to look for the host's
#                               terminfo db. All three common host paths are
#                               listed so the library degrades gracefully when
#                               the host has a full terminfo install.
#   --with-fallbacks          — compile these common terminal defs directly into
#                               libtinfow so basic terminal support works even
#                               with no host terminfo at all (headless containers).
#   --disable-static          — shared only; consistent with the rest of the tree.
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

make -j"$(nproc)"

# `make install` in the misc/ subdir tries to run tic (the terminfo compiler)
# to build the full terminfo database and write it to the paths listed in
# --with-default-terminfo-dir (e.g. /etc/terminfo). Those paths are host system
# paths that don't exist in the Nix sandbox and we can't write there anyway.
#
# We redirect the terminfo install by overriding `ticdir` on the make command
# line to a writable temp dir, then discarding the output. The fallback terminal
# definitions compiled directly into libtinfow (via --with-fallbacks) are
# sufficient for our use case, and the full terminfo database (~7 MB) would be
# dead weight in the tarball.
terminfo_tmp="$PBS_DEPS/share/terminfo-install-tmp"
mkdir -p "$terminfo_tmp"
make install "ticdir=$terminfo_tmp"
rm -rf "$terminfo_tmp"

# Drop ncurses's bin/ — it installs ncurses6-config and similar scripts that
# bake build-time /nix/store prefix paths. libedit finds ncurses via pkg-config.
rm -rf "$PBS_DEPS/bin"

# ncurses's build system installs static archives (*.a) alongside the shared
# libs even with --disable-static (the flag applies to libtool projects, but
# ncurses uses its own Makefile). Remove them — we ship .so only, and the .a
# files would add ~1 MB of dead weight to the tarball.
rm -f "$PBS_DEPS/lib"/lib*.a

# ncurses installs ~957 man pages and a tabset/ directory. Neither is useful
# in the portable PHP tarball: PHP's own build-php.sh drops PHP's man pages
# for the same reason. Remove these here before they merge into the tree.
rm -rf "$PBS_DEPS/share/man"
rm -rf "$PBS_DEPS/share/tabset"

# libedit's configure probes for tgetent in -lncurses/-lcurses/-ltermcap/-ltinfo
# and for headers ncurses.h/curses.h/termcap.h in include/ — none of which
# exist because --enable-widec appends a 'w' to every name (libncursesw,
# libtinfow, include/ncursesw/). Create compat symlinks so libedit's configure
# probes succeed. These are build-time-only from libedit's perspective; at
# runtime it will DT_NEEDED libtinfow directly (the symlink target soname).
for lib in ncurses tinfo form menu panel; do
  if [ -L "$PBS_DEPS/lib/lib${lib}w.so" ]; then
    ln -sf "lib${lib}w.so" "$PBS_DEPS/lib/lib${lib}.so"
    ln -sf "lib${lib}w.so.6" "$PBS_DEPS/lib/lib${lib}.so.6"
  fi
done

# Header compat: ncurses --enable-widec installs headers under include/ncursesw/
# but libedit looks in include/ directly for ncurses.h / curses.h / termcap.h.
for hdr in ncurses.h curses.h termcap.h; do
  if [ -f "$PBS_DEPS/include/ncursesw/$hdr" ]; then
    ln -sf "ncursesw/$hdr" "$PBS_DEPS/include/$hdr"
  fi
done

# Sanity: shared libs must exist with a clean NEEDED list (no /nix/store paths).
# We check libtinfow (the one libedit links against) and libncursesw.
for lib in libtinfow libncursesw; do
  libfile="$PBS_DEPS/lib/${lib}.so"
  real_lib="$(readlink -f "$libfile")"
  echo
  echo "--- ncurses ${lib} NEEDED audit ---"
  needed=$(readelf -d "$real_lib" | grep NEEDED || true)
  echo "$needed"
  if echo "$needed" | grep -q '/nix/store'; then
    echo "FATAL: ${lib} has /nix/store path in DT_NEEDED" >&2
    exit 1
  fi
done
echo "ncurses OK"
