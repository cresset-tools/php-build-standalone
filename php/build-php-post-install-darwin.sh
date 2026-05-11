# Darwin post-install hook. Sourced by build-php.sh.
# Rewrite the build-time libresolv LC_LOAD_DYLIB (pointing at nixpkgs's
# darwin.libresolv) to the consumer-visible system path. Doing it here
# rather than in finalize keeps the special case scoped to the PHP
# derivation — every other dep's /nix/store/* loads get the standard
# @rpath rewrite from finalize-darwin.sh.
#
# In V2 this also has to walk every shared extension .so: PHP's LDFLAGS
# includes -lresolv for ext/standard/dns.c, and Darwin's linker has no
# -Wl,--as-needed equivalent, so each .so picks up a stray libresolv
# LC_LOAD_DYLIB even though it never references the symbols.
_pbs_rewrite_libresolv() {
  local target="$1"
  while IFS= read -r dep; do
    case "$dep" in
      */libresolv*.dylib)
        /usr/bin/install_name_tool -change "$dep" /usr/lib/libresolv.9.dylib "$target"
        ;;
    esac
  done < <(/usr/bin/otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
}

for bin in "$PBS_DEPS/bin/php" "$PBS_DEPS/bin/php-fpm"; do
  [ -f "$bin" ] || continue
  _pbs_rewrite_libresolv "$bin"
done

if [ -d "$PBS_DEPS/lib/extensions" ]; then
  while IFS= read -r ext; do
    [ -f "$ext" ] || continue
    _pbs_rewrite_libresolv "$ext"
  done < <(find "$PBS_DEPS/lib/extensions" -type f -name '*.so')
fi
