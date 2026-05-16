# Linux pre-configure setup. Sourced by build-php.sh.
# Sets up the static-libstdc++ trick: don't bundle libstdc++.so.6 /
# libgcc_s.so.1 in the tarball. PBS's validator allows only the
# LSB-standard glibc set on x86_64; we match that.
#
# Two changes vs the default CC composition in setup-env-linux.sh:
#
# (1) Use -Wl,--as-needed (overriding setup-env-linux.sh's --no-as-needed).
#     When libtool re-adds -lstdc++ at the end of the PHP link line, we
#     want the linker to emit a DT_NEEDED only if some C++ symbol is
#     still unresolved — which won't happen, because libstdc++.a (2)
#     already resolved everything. --no-as-needed would force a
#     DT_NEEDED libstdc++.so.6 even though the static archive made it
#     redundant.
#
# (2) Static-link libstdc++ via libstdc++.a as a positional LDFLAG.
#     -static-libstdc++ is a clang++ driver flag and PHP's link runs
#     through cc, so we go direct: pass libstdc++.a as a positional
#     argument so the linker resolves C++ symbols from it before any
#     later -lstdc++. The archive is in our sysroot, copied there by
#     sysroot.nix from devtoolset-11.
libstdcxx_a="${PBS_SYSROOT}/usr/lib64/libstdc++.a"
if [ ! -f "$libstdcxx_a" ]; then
  echo "FATAL: $libstdcxx_a not present in sysroot" >&2
  exit 1
fi
export CC="${PBS_TOOLCHAIN}/bin/cc -Wl,--as-needed"
export CXX="${PBS_TOOLCHAIN}/bin/c++ -Wl,--as-needed"
export LDFLAGS="$LDFLAGS ${libstdcxx_a}"

# Suppress glibc's inline string macros. Our CentOS 7 / glibc 2.17 sysroot
# (manylinux floor) ships <bits/string2.h>, which under -O2 redefines
# strncmp/strcmp/etc. as 3-arg function-like macros. Glibc 2.25+ removed
# these inlines, so upstream PHP CI never trips on it — but ext/ffi/ffi.c
# in PHP 8.5+ uses `strncmp(p, ZEND_STRL("FFI_SCOPE"))`, and the C
# preprocessor counts top-level commas in strncmp's arg list BEFORE
# expanding ZEND_STRL, so it looks like 2 args to the macro and the
# build fails with "too few arguments provided to function-like macro
# invocation". Defining __NO_STRING_INLINES (a glibc-documented opt-out
# checked in <features.h>) prevents bits/string2.h from being included
# at all; the regular libc function is used instead, and modern compiler
# builtins inline the simple cases anyway, so there's no perf delta.
export CPPFLAGS="$CPPFLAGS -D__NO_STRING_INLINES"
