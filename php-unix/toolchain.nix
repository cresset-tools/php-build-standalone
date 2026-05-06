# The toolchain package set every dep + PHP-itself derivation needs as
# nativeBuildInputs.
#
# Critically:
#   - The CC/LD/AR/strip/etc tools come from `toolchain` (clang-toolchain.nix)
#     — wrapped clang against our glibc-2.17 sysroot, NOT nixpkgs's gcc.
#   - We do NOT include openssl / libxml2 / icu / etc. Those are bundled deps
#     we build ourselves; if they were here, the (already-unwrapped) toolchain
#     would still find them via PATH-style searches and silently link against
#     nixpkgs versions instead of ours.
{ pkgs, toolchain }:
with pkgs; [
  # The CC/CXX/LD/AR/etc binaries (wrapped clang, lld, llvm-tools).
  toolchain
  # Build orchestration tools — pure helpers that don't link against
  # libc, so it's fine that they come from modern nixpkgs.
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
  rpm
  cpio
]
