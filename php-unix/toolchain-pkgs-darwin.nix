# nativeBuildInputs for Darwin builds. Mirrors php-unix/toolchain.nix
# but drops Linux-only tools (patchelf, rpm, cpio) and skips the
# old-glibc sysroot wiring.
{ pkgs, toolchain }:
with pkgs; [
  toolchain
  # The macOS 11 SDK. Required as an explicit buildInput in newer
  # nixpkgs Darwin stdenvs to expose the full set of system headers
  # (`<arpa/nameser.h>`, frameworks under <CoreServices/…>, etc.). Without
  # it nixpkgs's clang gets a minimal SDK that's enough for autotools
  # probes (which silently skip headers when they're missing) but not
  # for meson's strict `cc.compiles()` checks. Required by glib 2.82's
  # gio/meson.build:35 ARPA C_IN gate at minimum.
  apple-sdk_11
  gnumake
  autoconf
  automake
  libtool
  pkg-config
  cmake
  bison
  flex
  re2c
  meson
  ninja
  file
  xz
  zstd
  gzip
  gnutar
  gnused
  gawk
  gnugrep
  findutils
  coreutils
  perl
  python3
  which
]
