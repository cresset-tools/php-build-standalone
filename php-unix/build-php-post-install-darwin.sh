# Darwin post-install hook. Sourced by build-php.sh.
# Rewrite the build-time libresolv LC_LOAD_DYLIB (pointing at nixpkgs's
# darwin.libresolv) to the consumer-visible system path. Doing it here
# rather than in finalize keeps the special case scoped to the PHP
# derivation — every other dep's /nix/store/* loads get the standard
# @rpath rewrite from finalize-darwin.sh.
for bin in "$PBS_DEPS/bin/php" "$PBS_DEPS/bin/php-fpm"; do
  [ -f "$bin" ] || continue
  while IFS= read -r dep; do
    case "$dep" in
      */libresolv*.dylib)
        /usr/bin/install_name_tool -change "$dep" /usr/lib/libresolv.9.dylib "$bin"
        ;;
    esac
  done < <(/usr/bin/otool -L "$bin" 2>/dev/null | awk 'NR>1 {print $1}')
done
