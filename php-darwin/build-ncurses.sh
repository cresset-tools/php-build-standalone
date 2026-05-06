#!/usr/bin/env bash
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

make -j"$(getconf _NPROCESSORS_ONLN)"

terminfo_tmp="$PBS_DEPS/share/terminfo-install-tmp"
mkdir -p "$terminfo_tmp"
make install "ticdir=$terminfo_tmp"
rm -rf "$terminfo_tmp"

rm -rf "$PBS_DEPS/bin"
rm -f "$PBS_DEPS/lib"/lib*.a
rm -rf "$PBS_DEPS/share/man"
rm -rf "$PBS_DEPS/share/tabset"

# Compat symlinks so libedit's configure finds the widec libs under
# their unsuffixed names. ncurses on Darwin produces .dylib instead of
# .so but the rest of the pattern is identical to the Linux build.
for lib in ncurses tinfo form menu panel; do
  if [ -L "$PBS_DEPS/lib/lib${lib}w.dylib" ] || [ -f "$PBS_DEPS/lib/lib${lib}w.dylib" ]; then
    ln -sf "lib${lib}w.dylib" "$PBS_DEPS/lib/lib${lib}.dylib"
    # Versioned symlink: ncurses uses libfoo.6.dylib on Darwin.
    if [ -e "$PBS_DEPS/lib/lib${lib}w.6.dylib" ]; then
      ln -sf "lib${lib}w.6.dylib" "$PBS_DEPS/lib/lib${lib}.6.dylib"
    fi
  fi
done

for hdr in ncurses.h curses.h termcap.h; do
  if [ -f "$PBS_DEPS/include/ncursesw/$hdr" ]; then
    ln -sf "ncursesw/$hdr" "$PBS_DEPS/include/$hdr"
  fi
done

for lib in libtinfow libncursesw; do
  libfile="$PBS_DEPS/lib/${lib}.dylib"
  [ -e "$libfile" ] || { echo "FATAL: $libfile not produced" >&2; exit 1; }
  echo "--- ncurses ${lib} LC_LOAD_DYLIB audit ---"
  otool -L "$libfile" || true
done
echo "ncurses OK"
