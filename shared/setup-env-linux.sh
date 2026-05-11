# Linux compile/link environment. Sourced by every per-dep build
# script on Linux. setup-env-darwin.sh is the macOS counterpart.
#
# clang from a custom toolchain wrapper (clang-toolchain.nix), pointed
# at a CentOS 7 / glibc 2.17 sysroot. The wrapper bakes --sysroot, -B,
# -L, -nostdinc, -static-libgcc, the dynamic-linker path, and libstdc++
# search paths into every CC invocation. Same load-bearing trick as
# python-build-standalone: modern compiler against an old sysroot,
# producing binaries with a glibc symbol floor at 2.17.
#
# Inputs (must be exported by the calling derivation):
#   PBS_TOOLCHAIN — $out of clang-toolchain.nix.
#   PBS_SYSROOT   — $out of sysroot.nix. Used by the few places we still
#                   need to thread an explicit path (e.g. positional
#                   libstdc++.a in PHP's link line).

: "${PBS_TOOLCHAIN:?must be set by the derivation}"
: "${PBS_SYSROOT:?must be set by the derivation}"

# CC / CXX point at the wrapper scripts in the toolchain. They already
# carry --target, --sysroot, -B, -L, -resource-dir, -isystem, -fuse-ld
# and -static-libgcc, plus a hardcoded -dynamic-linker.
#
# -Wl,--no-as-needed: keep DT_NEEDED entries even when libtool puts -l
# flags ahead of .o files. With clang's default --as-needed plus
# libtool ordering, libs that aren't referenced from any preceding
# object get dropped from DT_NEEDED — the .so still builds (shared
# linking is permissive) but downstream consumers fail to load it
# because the dependency edge is missing.
#
# lld does NOT need --copy-dt-needed-entries: it resolves indirect
# DT_NEEDED references transitively by default. Passing the flag to
# lld is a hard error ("unknown argument").
export CC="${PBS_TOOLCHAIN}/bin/cc -Wl,--no-as-needed"
export CXX="${PBS_TOOLCHAIN}/bin/c++ -Wl,--no-as-needed"
export AR="${PBS_TOOLCHAIN}/bin/ar"
export RANLIB="${PBS_TOOLCHAIN}/bin/ranlib"
export NM="${PBS_TOOLCHAIN}/bin/nm"
export STRIP="${PBS_TOOLCHAIN}/bin/strip"

# Generic "build a portable shared lib" flags.
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS=""

# RPATH: deliberately NOT set here. Threading literal "$ORIGIN" through
# bash → autoconf → libtool → Make without any layer expanding it is
# fragile. finalize-linux.sh runs `patchelf --force-rpath --set-rpath
# '$ORIGIN/../lib'` over every ELF at the end.
#
# Keep --disable-new-dtags so any rpath libtool decides to emit becomes
# DT_RPATH not DT_RUNPATH (defense in depth — finalize normalizes either).
export LDFLAGS="-Wl,--disable-new-dtags -Wl,-z,origin"

# LIBRARY_PATH is gcc/clang's env-var equivalent of -L. We need it
# because some build systems (bzip2's Makefile-libbz2_so notably)
# compose link commands as `$(CC) -shared $(OBJS)` with no $(LDFLAGS)
# reference, so library search paths in LDFLAGS never reach the
# linker. Expose the sysroot lib64 dir explicitly as a backstop.
export LIBRARY_PATH="${PBS_SYSROOT}/usr/lib64"

# NB: do NOT set LD_LIBRARY_PATH globally. We tried it; it works for
# conftest binaries but pollutes every other process the build spawns
# (bash, make, awk, ...) — those are built against modern glibc and
# explode with "GLIBC_2.34 not found" when they pick up our sysroot's
# glibc-2.17 libc.so.6 instead of their own. Per-dep scripts that
# need it set LD_LIBRARY_PATH scoped to a single command.

# Audit a freshly-built shared library and fail if the binary leaks
# any /nix/store path through DT_NEEDED.
pbs_audit_lib() {
  local lib="$1" name="$2"
  echo
  echo "--- ${name} NEEDED audit ---"
  local real_lib needed
  real_lib="$(readlink -f "$lib")"
  needed=$(readelf -d "$real_lib" | grep NEEDED || true)
  echo "$needed"
  if echo "$needed" | grep -q '/nix/store'; then
    echo "FATAL: ${name} has /nix/store path in DT_NEEDED" >&2
    return 1
  fi
}
# build-*.sh runs as `bash <script>` from mkDep's buildPhase, which
# spawns a fresh shell — so the function needs `export -f` to survive
# the exec boundary even though the env vars above propagate normally.
export -f pbs_audit_lib
