# Sourced by every per-dep build script. Sets the compile/link flags
# used across all bundled-dep builds.
#
# We use clang from a custom toolchain wrapper (php-unix/clang-toolchain.nix),
# pointed at a CentOS 7 / glibc 2.17 sysroot (php-unix/sysroot.nix). The
# wrapper bakes --sysroot, -B, -L, -nostdinc, -static-libgcc, the
# dynamic-linker path, and libstdc++ search paths into every CC
# invocation. Same load-bearing trick as python-build-standalone:
# modern compiler against an old sysroot, producing binaries with a
# glibc symbol floor at 2.17 (in practice ~2.14 for most code).
#
# Inputs (must be exported by the derivation calling this):
#   PBS_TOOLCHAIN — $out of php-unix/clang-toolchain.nix.
#                   Contains bin/cc, bin/c++, bin/ld, etc.
#   PBS_SYSROOT   — $out of php-unix/sysroot.nix. Used by the few
#                   places we still need to thread an explicit path
#                   (e.g. positional libstdc++.a in PHP's link line).

: "${PBS_TOOLCHAIN:?must be set by the derivation}"
: "${PBS_SYSROOT:?must be set by the derivation}"

# CC / CXX point at the wrapper scripts in the toolchain. They already
# carry --target, --sysroot, -B, -L, -resource-dir, -isystem, -fuse-ld
# and -static-libgcc, plus a hardcoded -dynamic-linker. Anything we add
# here is purely above-and-beyond.
#
# -Wl,--no-as-needed is appended at the linker level to keep DT_NEEDED
# entries even when libtool puts -l flags ahead of the .o files. With
# clang's default --as-needed plus libtool ordering, libs that aren't
# referenced from any preceding object get dropped from DT_NEEDED — the
# .so still builds (shared linking is permissive) but downstream
# consumers fail to load it because the dependency edge is missing.
#
# lld does NOT need --copy-dt-needed-entries: it resolves indirect
# DT_NEEDED references transitively by default (the libxml2/log10 case
# from binutils-2.22+ is a GNU-ld-only quirk). Passing the flag to lld
# is a hard error ("unknown argument"). If/when we switch back to a
# GNU-ld-driven link, re-add it.
export CC="${PBS_TOOLCHAIN}/bin/cc -Wl,--no-as-needed"
export CXX="${PBS_TOOLCHAIN}/bin/c++ -Wl,--no-as-needed"
export AR="${PBS_TOOLCHAIN}/bin/ar"
export RANLIB="${PBS_TOOLCHAIN}/bin/ranlib"
export NM="${PBS_TOOLCHAIN}/bin/nm"
export STRIP="${PBS_TOOLCHAIN}/bin/strip"

# CFLAGS — generic "build a portable shared lib" flags. -O2 -fPIC is
# nothing surprising. Note we do NOT pass any -L / -isystem / -B / -L
# flags here; the wrapper script already handles all of those.
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS=""

# RPATH: deliberately NOT set here. Threading literal "$ORIGIN" through
# bash → autoconf → libtool → Make → /bin/sh without any layer expanding
# it is fragile and differs per build system. Instead, finalize.sh runs
# `patchelf --force-rpath --set-rpath '$ORIGIN/../lib'` over every ELF
# at the end, uniformly. Same approach as PBS.
#
# We DO keep --disable-new-dtags so any rpath libtool/autoconf decide to
# emit becomes DT_RPATH not DT_RUNPATH (defense in depth — finalize
# normalizes either way).
export LDFLAGS="-Wl,--disable-new-dtags -Wl,-z,origin"

# LIBRARY_PATH is gcc/clang's env-var equivalent of -L. We need it
# because some build systems (bzip2's Makefile-libbz2_so notably) compose
# link commands as `$(CC) -shared $(OBJS)` with no $(LDFLAGS) reference,
# so library search paths in LDFLAGS never reach the linker. By the
# time we get here the wrapper's -L already covers the sysroot paths,
# but expose the sysroot lib64 dir explicitly anyway as a backstop.
export LIBRARY_PATH="${PBS_SYSROOT}/usr/lib64"

# LD_LIBRARY_PATH lets the just-built executables find their libc at
# runtime when autoconf's "can the compiler run programs?" probe (and
# similar in-build invocations) executes them. The wrapper hardcodes
# ${PBS_SYSROOT}/lib64/ld-linux-x86-64.so.2 as the build-time .interp;
# that ld.so then resolves DT_NEEDED libc.so.6 via this search path.
# finalize.sh strips the sysroot-baked interp + DT_RPATH at the end,
# so this is purely a sandbox-runtime concern.
# NB: do NOT set LD_LIBRARY_PATH here. We tried it; it works for
# conftest binaries but pollutes every other process the build
# spawns (bash, make, awk, ...) — those are built against modern
# glibc and explode with "GLIBC_2.34 not found" when they pick up
# our sysroot's glibc-2.17 libc.so.6 instead of their own.
#
# Instead, the clang wrapper bakes -Wl,-rpath,${PBS_SYSROOT}/lib64
# into every link line so just-built test binaries find their old
# libc via DT_RPATH (which IS process-local). finalize.sh strips
# those build-time RPATHs and resets to $ORIGIN/../lib.
