# Sourced by every per-dep build script. Sets the toolchain compile/link
# flags used across all bundled-dep builds.
#
# Inputs (must be exported by the caller — i.e. the derivation):
#   PBS_GLIBC_LIB         — ${pkgs.glibc}/lib       (crt1.o etc + libc)
#   PBS_GCC_LIBGCC        — ${pkgs.gcc-unwrapped.lib}/lib  (libgcc_s.so)
#   PBS_GLIBC_DEV_INCLUDE — ${pkgs.glibc.dev}/include (rarely needed; gcc-unwrapped
#                           is configured with --with-native-system-header-dir
#                           pointing here already, so explicit -isystem is redundant)

: "${PBS_GLIBC_LIB:?must be set by the derivation}"
: "${PBS_GCC_LIBGCC:?must be set by the derivation}"

# Three flags are baked into CC itself rather than just CFLAGS/LDFLAGS,
# because they have to land at position 0 on every link command — libtool
# puts user LDFLAGS at the END (after libs and even after the .so files
# being linked against), too late to affect anything they're meant to
# control:
#
#   -B${PBS_GLIBC_LIB} — startup-files lookup. Some build systems
#     (libtool's testdso.la rule in libxml2 is the canonical offender)
#     compose link commands from templates that don't include all of
#     CFLAGS/LDFLAGS. Embedding -B in CC means every gcc invocation
#     gets it.
#
#   -Wl,--no-as-needed — ensures every -l on the link line produces a
#     DT_NEEDED entry. With the default --as-needed, libs that come
#     before the .o files (libtool sometimes orders them that way) get
#     dropped because no symbol is yet undefined when they're processed.
#     The shared lib still builds (shared linking is permissive about
#     undefined symbols) but its DT_NEEDED is missing libs it actually
#     uses, breaking downstream consumers.
#
#   -Wl,--copy-dt-needed-entries — when linking an executable (xmlcatalog,
#     xmllint, …) against a shared lib (libxml2.so) that itself has
#     DT_NEEDED entries (libm, libz), modern ld defaults to NOT consulting
#     those transitive deps for symbol resolution. The executable then
#     fails to link with "undefined reference to log10@GLIBC_2.2.5" even
#     though libxml2.so correctly NEEDED libm.so.6. This flag restores the
#     pre-binutils-2.22 behavior of walking DT_NEEDED transitively.
export CC="gcc -B${PBS_GLIBC_LIB} -Wl,--no-as-needed -Wl,--copy-dt-needed-entries"
export CXX="g++ -B${PBS_GLIBC_LIB} -Wl,--no-as-needed -Wl,--copy-dt-needed-entries"
export AR=ar
export RANLIB=ranlib
export NM=nm
export STRIP=strip

# -L for libgcc_s appears in CFLAGS (not just LDFLAGS) because some
# configure scripts (zlib's hand-rolled one, notably) test shared-lib
# support using only $CFLAGS/$SFLAGS. Without -L{libgcc} reachable via
# CFLAGS, the test fails to find -lgcc_s and configure silently falls
# back to static-only — which is precisely what we don't want.
export CFLAGS="-O2 -fPIC -L${PBS_GCC_LIBGCC} -L${PBS_GLIBC_LIB}"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS=""

# RPATH: deliberately NOT set here. Threading literal "$ORIGIN" through
# bash → autoconf → libtool → Make → /bin/sh without any layer expanding
# it is fragile and differs per build system. Instead, finalize.sh runs
# `patchelf --force-rpath --set-rpath '$ORIGIN/../lib'` over every ELF
# at the end, uniformly. Same approach as PBS
# (cpython-unix/build-cpython.sh:872).
#
# We DO keep --disable-new-dtags so any rpath libtool/autoconf decide to
# emit becomes DT_RPATH not DT_RUNPATH (defense in depth — finalize
# normalizes either way).
export LDFLAGS="-L${PBS_GLIBC_LIB} -L${PBS_GCC_LIBGCC} -Wl,--disable-new-dtags -Wl,-z,origin"

# LIBRARY_PATH is gcc's env-var equivalent of -L. Some build systems
# (bzip2's Makefile-libbz2_so is the canonical case) compose link
# commands as `$(CC) -shared $(OBJS)` with no $(LDFLAGS) reference, so
# our -L flags in LDFLAGS never reach the linker. Without LIBRARY_PATH,
# ld then can't find libgcc_s.so or crt files.
#
# This is redundant with LDFLAGS for most build systems, but harmless:
# gcc adds LIBRARY_PATH dirs to the link search list at link time.
export LIBRARY_PATH="${PBS_GLIBC_LIB}:${PBS_GCC_LIBGCC}"
