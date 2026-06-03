# nativeBuildInputs for musl (x86_64-unknown-linux-musl) builds.
#
# Mirrors shared/toolchain.nix (the glibc Linux set) — musl is ELF/Linux,
# so it keeps patchelf and the same orchestration tools — but drops the
# old-glibc-sysroot-only bits (rpm, cpio, which were just for assembling
# the CentOS sysroot; the musl leg has no such sysroot).
#
# `pkgs` here is `pkgsMusl` (see flake.nix contextFor), but the build
# orchestration tools (make, autoconf, …) are pure helpers — it's fine for
# them to be musl-built; they don't end up in any shipped artifact.
{ pkgs, toolchain }:
with pkgs; [
  # The CC/CXX/LD/AR/etc binaries (wrapped musl clang, lld, llvm-tools).
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
