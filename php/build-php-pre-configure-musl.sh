# musl pre-configure setup. Sourced by build-php.sh on the musl leg.
# Counterpart to build-php-pre-configure-linux.sh (glibc); same
# static-libstdc++ trick, sourced from the musl toolchain instead of the
# CentOS sysroot, and without the glibc-only string-inline workaround.
#
# (1) Use -Wl,--as-needed (overriding setup-env-musl.sh's --no-as-needed)
#     so the final PHP link only emits a DT_NEEDED for libstdc++.so.6 if a
#     C++ symbol is still unresolved after the static archive — it won't be,
#     keeping libstdc++ out of the interpreter tarball's DT_NEEDED surface.
#
# (2) Static-link libstdc++ via libstdc++.a as a positional LDFLAG.
#     -static-libstdc++ is a clang++ driver flag and PHP links through cc,
#     so we pass the archive positionally. toolchain-musl.nix exposes it at
#     $PBS_TOOLCHAIN/lib/libstdc++.a (from pkgsMusl's gcc).
#
# Note: no -D__NO_STRING_INLINES here. That guards against glibc's
# <bits/string2.h> function-like string macros (PHP 8.5 ext/ffi); musl has
# no such header, so the flag is unnecessary on this leg.
libstdcxx_a="${PBS_TOOLCHAIN}/lib/libstdc++.a"
if [ ! -f "$libstdcxx_a" ]; then
  echo "FATAL: $libstdcxx_a not present in the musl toolchain" >&2
  exit 1
fi
export CC="${PBS_TOOLCHAIN}/bin/cc -Wl,--as-needed"
export CXX="${PBS_TOOLCHAIN}/bin/c++ -Wl,--as-needed"
export LDFLAGS="$LDFLAGS ${libstdcxx_a}"

# PHP 8.1's main/streams/cast.c casts its stream seeker to musl's
# cookie_seek_function_t with a mismatched signature (musl's fopencookie
# seek takes off_t* where PHP's older code assumed otherwise). clang 16+
# promotes -Wincompatible-function-pointer-types to a hard error. PHP 8.2+
# fixed this (COOKIE_SEEKER_USES_OFF64_T detection); 8.1 needs the warning
# demoted. The cast is ABI-safe on musl (both are pointers to a 64-bit
# off_t), and Alpine builds php81 on musl the same way.
export CFLAGS="$CFLAGS -Wno-error=incompatible-function-pointer-types"

# musl's dynamic linker does not support GNU ifunc (R_X86_64_IRELATIVE,
# reloc type 37) — it aborts at load with "unsupported relocation type 37".
# PHP/Zend uses __attribute__((ifunc)) resolvers for its SSE/AVX string
# dispatch when the compiler supports the attribute (clang does, and the
# configure probe is compile-only so it passes). Pre-seed the autoconf
# cache var to "no" so HAVE_FUNC_ATTRIBUTE_IFUNC stays undefined; Zend then
# falls back to its function-pointer SIMD dispatch (initialized at startup),
# which works on musl. The probe is AX_GCC_FUNC_ATTRIBUTE(ifunc).
export ax_cv_have_func_attribute_ifunc=no
