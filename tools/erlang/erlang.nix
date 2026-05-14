# Erlang/OTP bundle. Built dynamically linked against PBS's bundled
# OpenSSL (crypto NIF needs it) and our bundled zlib; everything else is
# in-tree under OTP's source. Tree is relocatable via finalize's
# $ORIGIN-rewrite — same pattern PHP/MariaDB/Redis use.
#
# Why we build OTP from source (vs the Temurin-style repackage we used
# for the JDK): Erlang has no portable upstream prebuilt — the closest
# things are Erlang Solutions' distro packages (glibc-version-pinned,
# not relocatable) and the rabbitmq-server-from-source Docker images
# (container artifacts, not redistributable tarballs). Building from
# source with our toolchain gives us the same libc floor as the rest of
# the bundle and lets us cleanly drop the GUI dev-tools we don't ship.
#
# `erlangSpec` is sources.erlang. Distinct from a future PECL-style
# extension; there isn't one today, but the naming follows the
# redisSpec/redisServerSpec split in flake.nix.
#
# Downstream consumer: tools/rabbitmq/ injects this into install/erlang/
# (RabbitMQ's launcher honors ERLANG_HOME), and the Erlang tool tarball
# itself is published as a standalone artifact for users who want a
# relocatable Erlang VM independent of RabbitMQ.
{ mkDep, pkgs, erlangSpec, openssl, zlib, ncurses }:
let
  inherit (pkgs) stdenv lib;
  # Half-precision float helpers (__extendhfsf2 / __truncsfhf2 /
  # __truncdfhf2) used by OTP 27's erl_bits.c. Our toolchain links
  # devtoolset-11's libgcc.a (`-rtlib=libgcc -static-libgcc` in
  # clang-toolchain.nix), which does NOT export these symbols. clang's
  # compiler-rt builtins archive does — we link it positionally for the
  # Erlang build so beam.jit's link succeeds. Linux-only: Darwin's
  # system libc/libcompiler_rt has the helpers already.
  compilerRtBuiltins =
    if stdenv.isDarwin then null
    else "${pkgs.llvmPackages_18.compiler-rt}/lib/linux/libclang_rt.builtins-x86_64.a";
in
mkDep {
  name = "erlang";
  buildScript = ./build-erlang.sh;
  version = erlangSpec.version;
  src = pkgs.fetchurl { inherit (erlangSpec) url sha256; };
  # ncurses gives `erl`'s shell line-editing the upgraded experience.
  # Configure auto-detects it via the curses probe; PBS_DEP_NCURSES is
  # surfaced into the env via mkDep so the probe finds our bundled one
  # rather than the host's.
  deps = [ openssl zlib ncurses ];
  # OTP's configure is autoconf + perl-driven scripts. perl is mandatory
  # (used by the `erts/autoconf/*` machinery and the install scripts);
  # pkg-config is consulted by the SSL/crypto detection probe; m4 and
  # autoconf are used to regenerate configure on platforms that need it
  # (we don't, but `make install`'s release/ step shells out to them in
  # some configurations and complains otherwise).
  extraInputs = with pkgs; [ perl pkg-config autoconf m4 ];
  extraEnv = lib.optionalAttrs (compilerRtBuiltins != null) {
    PBS_CLANG_RT_BUILTINS = compilerRtBuiltins;
  };
}
