# ICU bundled-dep derivation. Provides libicuuc/libicui18n/libicudata/
# libicuio for PHP's intl extension.
#
# C++ runtime story diverges by platform — handled in Nix here, not in
# the bash script:
#   Linux:  static-link libstdc++ + libgcc into each libicu*.so. Avoids
#           shipping libstdc++.so.6 in the tarball and dodges ICU's
#           bootstrap problem (icupkg needs C++ runtime to run during
#           build, but libstdc++.so.6 isn't on LD_LIBRARY_PATH yet).
#   Darwin: dynamic-link against /usr/lib/libc++.1.dylib (system-stable
#           ABI back to Mavericks). Saves ~3 MB.
{ mkDep, pkgs }:
let inherit (pkgs) stdenv lib; in
mkDep {
  name = "icu";
  extraEnv = {
    # runConfigureICU's first arg is its own platform name (not an
    # autotools triple).
    PBS_ICU_TARGET = if stdenv.isDarwin then "MacOSX" else "Linux";
    # Linux-only static-libstdc++/static-libgcc; empty on Darwin where
    # we want dynamic libc++.
    PBS_ICU_EXTRA_LDFLAGS = if stdenv.isDarwin
      then ""
      else "-static-libstdc++ -static-libgcc";
  };
}
