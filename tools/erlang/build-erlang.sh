#!/usr/bin/env bash
# Build Erlang/OTP into ${PBS_DEPS}.
#
# OTP install layout under $PREFIX:
#   $PREFIX/bin/{erl, erlc, escript, ct_run, dialyzer, typer, run_erl,
#                to_erl, epmd}         shell-script wrappers (top-level
#                                      entrypoints copied from
#                                      lib/erlang/bin/<name>)
#   $PREFIX/lib/erlang/                actual OTP installation root
#       bin/                           wrappers (sourced of truth — what
#                                      $PREFIX/bin/ scripts call into)
#       erts-<v>/bin/                  native binaries (beam.smp,
#                                      erlexec, dyn_erl, …) — the actual
#                                      VM
#       erts-<v>/lib/                  liberts_internal.a + driver .so
#       lib/<app>-<v>/                 each OTP app: ebin/*.beam + priv/
#                                      (priv/lib/<nif>.so when an app
#                                      ships a NIF, e.g. crypto, asn1,
#                                      odbc)
#       releases/<rel>/                release boot scripts
#       usr/lib/                       erl_call etc. (helper binaries)
#
# Relocation: OTP's `make install` runs a perl script (lib/erlang/Install
# on disk; lives under release/<vsn>/Install in the source tree) which
# substitutes the absolute ROOTDIR into every shell wrapper. Same problem
# CPython's sysconfig has — we patch the wrappers post-install to use
# `$(cd -P "$(dirname "$0")/<rel>" && pwd)` so the install tree is
# relocatable. See _make_relocatable() at the bottom of this script.

set -euo pipefail

: "${PBS_SRC_ERLANG:?}"
: "${PBS_VER_ERLANG:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_OPENSSL:?}"
: "${PBS_DEP_ZLIB:?}"
: "${PBS_DEP_NCURSES:?}"

# Upstream tarball extracts to otp_src_<version>/, not erlang-<version>/.
# mkDep's name-based default doesn't fit; do the extract ourselves.
src_dir="$PBS_SOURCES/otp_src_${PBS_VER_ERLANG}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_ERLANG" -C "$PBS_SOURCES"
cd "$src_dir"

# Half-precision float helpers for the beam.jit link. OTP 27's
# erl_bits.c emits references to __extendhfsf2 / __truncsfhf2 /
# __truncdfhf2 (compiler-generated calls for _Float16 ↔ float
# conversions in `<<X:16/float>>` bitsyntax). Our clang-toolchain
# pins -rtlib=libgcc + -static-libgcc against devtoolset-11's
# libgcc.a, which does NOT carry those helpers — devtoolset-11 was
# built before GCC 12 enabled half-precision support by default on
# x86_64. clang's own compiler-rt builtins archive does carry them;
# we link it positionally (Linux only — Darwin's system runtime has
# the helpers).
if [ -n "${PBS_CLANG_RT_BUILTINS:-}" ]; then
  [ -f "$PBS_CLANG_RT_BUILTINS" ] \
    || { echo "FATAL: PBS_CLANG_RT_BUILTINS does not exist: $PBS_CLANG_RT_BUILTINS" >&2; exit 1; }
  # Positional archive at the END of LDFLAGS — lld processes left-to-
  # right and the .o files referencing the helpers come before it in
  # the link line, so the archive's matching members get pulled in.
  export LDFLAGS="$LDFLAGS $PBS_CLANG_RT_BUILTINS"
fi

# Tell configure to use our bundled OpenSSL for the crypto NIF.
#
# --enable-dynamic-ssl-lib   crypto.so links libcrypto.so dynamically
#                            (DT_NEEDED libcrypto.so.3, resolved via
#                            finalize's $ORIGIN-relative RPATH). The
#                            default with --with-ssl=<path> is the same
#                            dynamic mode; we pass the flag explicitly to
#                            make the intent obvious and to fail loudly
#                            if upstream ever flips it.
# --disable-builtin-zlib     OTP's configure auto-detects system zlib;
#                            our PBS_DEP_ZLIB is on CFLAGS/LDFLAGS via
#                            mkDep's appendDepFlags, so the system probe
#                            picks up our copy. Without this flag, OTP
#                            falls back to its vendored copy under
#                            erts/emulator/zlib/ — which works but means
#                            two zlib copies ship. Use ours instead.
#
# Disabled subsystems (developer GUIs / niche tooling; trim ~80MB):
# --without-wx              wxWidgets-based observer GUI
# --without-debugger        wxWidgets-based debugger GUI
# --without-observer        runtime observer GUI (wx)
# --without-et              event tracer GUI (wx)
# --without-megaco          telecom protocol; large, not used by RabbitMQ
# --without-jinterface      Java-Erlang bridge; we don't ship a JDK in
#                           this tarball
# --without-javac           Java compiler probe; without -javac configure
#                           still tries to find javac. We never need it.
# --without-odbc            DB ODBC bindings; requires unixodbc-dev and
#                           pulls in a NIF we'd then have to bundle.
#                           RabbitMQ doesn't use it; PHP devs who want
#                           DB access do it from PHP, not Erlang.
#
# RPATH wiring: setup-env-linux.sh exports `-Wl,--disable-new-dtags
# -Wl,-z,origin` in LDFLAGS, and finalize rewrites every ELF's RPATH at
# tarball-assembly time. We don't pre-encode any RPATH here — finalize's
# soname→storeName map (built from tree.nix's PBS_STORE_MANIFEST) is the
# single source of truth.
./configure \
  --prefix="$PBS_DEPS" \
  --with-ssl="$PBS_DEP_OPENSSL" \
  --enable-dynamic-ssl-lib \
  --disable-builtin-zlib \
  --without-wx \
  --without-debugger \
  --without-observer \
  --without-et \
  --without-megaco \
  --without-jinterface \
  --without-javac \
  --without-odbc

# OTP's `make` step bootstraps by invoking freshly-built `erlc` and
# `erl` to compile .erl → .beam for all OTP applications. Those
# binaries are dynamically linked against our bundled ncurses
# (libtinfow.so.6) — the finalize-encoded $ORIGIN-relative RPATH isn't
# in place yet at this stage, so we need to point ld.so at the lib
# search path for the duration of the build. mkDep accumulates
# PBS_DEPS_LDPATH on Linux for exactly this scoped use; setup-env-
# linux.sh deliberately does NOT set LD_LIBRARY_PATH globally because
# it would poison subshells linked against modern glibc (bash, make,
# awk) and crash them with "GLIBC_2.34 not found" against the
# sysroot's libc-2.17.
LD_LIBRARY_PATH="$PBS_DEPS_LDPATH" make -j"$NIX_BUILD_CORES"
# `make install` runs the install-perl script, which itself shells
# out to `erl` to generate boot scripts. Same LD_LIBRARY_PATH need.
LD_LIBRARY_PATH="$PBS_DEPS_LDPATH" make install

# Strip release docs / man pages / example sources. Reduces the OTP tree
# from ~280MB to ~110MB; CLI/server use cases never touch these.
rm -rf "$PBS_DEPS/lib/erlang/man" \
       "$PBS_DEPS/lib/erlang/doc" \
       "$PBS_DEPS/lib/erlang/examples"
# Per-app examples and doc/ subdirs aren't covered by the top-level rm.
find "$PBS_DEPS/lib/erlang/lib" -mindepth 2 -maxdepth 2 \
     \( -name examples -o -name doc -o -name man \) -type d \
     -exec rm -rf {} + 2>/dev/null || true

# Strip OTP apps the bougie target audience doesn't need at runtime.
# Saves ~15 MB on top of the .erl-source strip below; downstream
# consumers that want type analysis or test-framework support should
# install Erlang separately from upstream.
#
#  dialyzer / typer    static type analyzer + frontend — pure dev tool;
#                      RabbitMQ doesn't load it at runtime.
#  common_test         OTP's xUnit-equivalent test framework. RabbitMQ
#                      uses its own framework for its own tests; the
#                      shipped artifact never runs them.
#  snmp                Simple Network Management Protocol agent +
#                      manager. RabbitMQ does not load snmp; users who
#                      want SNMP-style monitoring use the management
#                      plugin's prometheus endpoint.
#  diameter            3GPP / IETF Diameter telecom protocol. RabbitMQ
#                      does not load it.
#
# Removing the .app dir is sufficient — Erlang's release-handler only
# loads apps that exist under lib/erlang/lib/<app>-<v>/, so nothing
# else needs patching. The bin/ wrappers for typer and ct_run are
# removed below since they'd error out without their apps.
for app in dialyzer common_test snmp diameter; do
  rm -rf "$PBS_DEPS/lib/erlang/lib/${app}-"*
done

# Wrapper scripts that reference the stripped apps. These are
# generated by OTP's install script — POSIX shell heading into
# `erl -boot start_clean -run <app> …`. Without their app dir,
# they'd fail at boot with "module <app> not found".
for bin in typer ct_run dialyzer; do
  rm -f "$PBS_DEPS/bin/$bin" "$PBS_DEPS/lib/erlang/bin/$bin"
done

# Strip .erl source files from the OTP apps. OTP ships them alongside
# the compiled .beam (in lib/erlang/lib/<app>-<v>/src/) for dialyzer's
# abstract-code analysis, runtime code:get_source/1 reflection, and
# IDE jump-to-source — none of which apply at runtime. Saves ~30 MB.
#
# We keep:
#   include/*.hrl   — referenced via -include() at compile time in
#                     downstream apps (rare but RabbitMQ does it for
#                     a few records); irrelevant after compile, but
#                     they're <1 MB total. Leave alone.
#   src/*.app.src   — template that OTP uses to derive .app metadata;
#                     not loaded at runtime, but doesn't cost much
#                     and removing it confuses some release tooling.
#                     Leave alone.
#   c_src/          — C sources for the NIFs (e.g. crypto, asn1).
#                     Compiled-and-linked at build time; the resulting
#                     priv/lib/<nif>.so is what the VM loads. We strip
#                     c_src/ to drop ~3 MB more.
find "$PBS_DEPS/lib/erlang/lib" -name '*.erl' -delete 2>/dev/null || true
find "$PBS_DEPS/lib/erlang/lib" -mindepth 2 -maxdepth 2 \
     -name c_src -type d -exec rm -rf {} + 2>/dev/null || true

# ---- Make the install tree relocatable ----
#
# OTP's install script already implements relocation in lib/erlang/bin/*
# wrappers: each one computes a `dyn_rootdir` by exec'ing
# `dyn_erl --realpath` (a tiny C binary under erts-<v>/bin/) and using
# its result if it differs from the hardcoded ROOTDIR baked in at
# install time. So lib/erlang/bin/erl already works correctly when the
# tree is moved — *if* it can find dyn_erl, which it does because from
# lib/erlang/bin/ the relative path `../erts-<v>/bin/dyn_erl` resolves
# to the actual file.
#
# However, OTP also installs $PBS_DEPS/bin/erl as a regular-file COPY of
# lib/erlang/bin/erl (not a symlink — unlike the other top-level entries
# erlc/dialyzer/escript/… which ARE symlinks). That copy carries the
# same `dyn_erl_path="${progdir}/../erts-<v>/bin/dyn_erl"` lookup — but
# from $PBS_DEPS/bin/, `../erts-<v>/bin/dyn_erl` resolves to
# $PBS_DEPS/erts-<v>/bin/dyn_erl, which doesn't exist (dyn_erl is under
# $PBS_DEPS/lib/erlang/erts-<v>/bin/). So the dyn_erl-based relocation
# silently falls through, and bin/erl uses the hardcoded ROOTDIR =
# $PBS_DEPS/lib/erlang absolute path. After finalize's text-detoxify
# pass that absolute path becomes /__PBS_PREFIX__/lib/erlang, and bin/erl
# exec's /__PBS_PREFIX__/lib/erlang/erts-<v>/bin/erlexec — which fails.
#
# A plain symlink would NOT fix this: dyn_erl_path is built from
# `dirname "$0"`, and $0 stays the symlink path (POSIX sh doesn't
# resolve), so progdir is still bin/.
#
# A plain symlink doesn't fix this either: when sh runs the script via
# the symlink, $0 is still the symlink path (POSIX sh doesn't resolve
# symlinks), so dirname stays `bin/` and the dyn_erl lookup still fails.
# We've seen OTP's `make install` produce $PBS_DEPS/bin/erl as EITHER
# a regular-file copy or a symlink depending on the install step's
# state — handle both by unconditionally rewriting.
#
# Fix: replace $PBS_DEPS/bin/erl with a thin stub that exec's the
# canonical wrapper at a path the wrapper's own progdir/dyn_erl_path
# logic will resolve correctly. The exec'd $0 becomes
# "$PBS_DEPS/bin/../lib/erlang/bin/erl", which makes progdir =
# $PBS_DEPS/bin/../lib/erlang/bin and dyn_erl_path =
# $PBS_DEPS/bin/../lib/erlang/bin/../erts-<v>/bin/dyn_erl, i.e. the real
# file. dyn_rootdir then resolves via dyn_erl --realpath to the actual
# install location, regardless of where the tree was extracted.
rm -f "$PBS_DEPS/bin/erl"
cat > "$PBS_DEPS/bin/erl" <<'STUB_EOF'
#!/bin/sh
exec "$(dirname "$0")/../lib/erlang/bin/erl" "$@"
STUB_EOF
chmod +x "$PBS_DEPS/bin/erl"

# Final sanity: the headline binaries must exist and be exec.
for b in erl erlc escript epmd; do
  bin="$PBS_DEPS/bin/$b"
  [ -x "$bin" ] || { echo "FATAL: $bin not present/executable" >&2; exit 1; }
done

# beam.smp is the actual VM — without it, every `erl` invocation is a
# silent shell-exec failure. erts-<v>/bin/beam.smp is what `erlexec`
# launches; pin the existence explicitly so a misconfigured build
# fails here, not at first-run time on a user's machine.
beam_smp=$(find "$PBS_DEPS/lib/erlang" -maxdepth 4 -name beam.smp -type f | head -1)
[ -n "$beam_smp" ] && [ -x "$beam_smp" ] \
  || { echo "FATAL: beam.smp not present/executable under $PBS_DEPS/lib/erlang/erts-*/bin/" >&2; exit 1; }

# crypto NIF must have been built — assert its presence and DT_NEEDED
# libcrypto. The whole point of --with-ssl=$PBS_DEP_OPENSSL.
crypto_nif=$(find "$PBS_DEPS/lib/erlang/lib" -name crypto.so -type f 2>/dev/null | head -1)
if [ -z "$crypto_nif" ]; then
  echo "FATAL: crypto NIF (crypto.so) not produced — --with-ssl probe failed silently?" >&2
  exit 1
fi

# Linux-only post-build audits.
if [ -z "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  pbs_audit_lib "$beam_smp" beam.smp
  pbs_audit_lib "$crypto_nif" crypto.so
fi

echo "erlang OK"
