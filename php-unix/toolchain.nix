# The toolchain — packages every dep and PHP-itself derivation needs as
# nativeBuildInputs. Same set as the devShell. Critically, this list
# does NOT include openssl/libxml2/icu/etc. Those are bundled deps we
# build ourselves via separate derivations; if they were here, the
# (already-unwrapped) toolchain would still find them via PATH-style
# searches and silently link against nixpkgs versions instead of ours.
{ pkgs }:
with pkgs; [
  gcc-unwrapped
  gcc-unwrapped.lib
  binutils-unwrapped
  glibc
  glibc.dev
  gnumake
  autoconf
  automake
  libtool
  pkg-config
  cmake
  bison
  flex
  re2c
  patchelf
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
