# Linux compat symlinks for ncurses widec libs. Sourced by build-ncurses.sh.
# Linux soversioning convention: libfoo.so.<major> (suffix-after-extension).
for lib in ncurses tinfo form menu panel; do
  [ -L "$PBS_DEPS/lib/lib${lib}w.so" ] || continue
  ln -sf "lib${lib}w.so"   "$PBS_DEPS/lib/lib${lib}.so"
  ln -sf "lib${lib}w.so.6" "$PBS_DEPS/lib/lib${lib}.so.6"
done
