# nativeBuildInputs for Darwin builds. Mirrors php-unix/toolchain.nix
# but drops Linux-only tools (patchelf, rpm, cpio) and skips the
# old-glibc sysroot wiring.
{ pkgs, toolchain }:
with pkgs; [
  toolchain
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
