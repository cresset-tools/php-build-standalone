# Darwin compat symlinks for ncurses widec libs. Sourced by build-ncurses.sh.
# Darwin soversioning convention: libfoo.<major>.dylib (suffix-before-extension).
for lib in ncurses tinfo form menu panel; do
  base="$PBS_DEPS/lib/lib${lib}w.dylib"
  [ -L "$base" ] || [ -f "$base" ] || continue
  ln -sf "lib${lib}w.dylib" "$PBS_DEPS/lib/lib${lib}.dylib"
  if [ -e "$PBS_DEPS/lib/lib${lib}w.6.dylib" ]; then
    ln -sf "lib${lib}w.6.dylib" "$PBS_DEPS/lib/lib${lib}.6.dylib"
  fi
done
