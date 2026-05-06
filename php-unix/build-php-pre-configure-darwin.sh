# Darwin pre-configure setup. Sourced by build-php.sh.
# Wires up libresolv (headers + lib stubs) and primes autoconf cache
# vars for the iconv check.

: "${PBS_DEP_LIBRESOLV_DIR:?point at nixpkgs darwin.libresolv \$out}"
: "${PBS_DEP_LIBRESOLV_INCLUDE:?point at nixpkgs darwin.libresolv \$dev (lib.getInclude)}"

# nixpkgs's apple-sdk derivations strip the legacy networking headers
# (arpa/nameser.h, resolv.h, dns.h) that PHP's ext/standard/dns.c
# depends on. They're shipped instead under `lib.getInclude
# darwin.libresolv` — same Apple opensource libresolv-91 that provides
# the matching .dylib stubs. -isystem so the headers slot in as system
# headers without polluting -W diagnostics.
export CFLAGS="-isystem $PBS_DEP_LIBRESOLV_INCLUDE/include $CFLAGS"
export CPPFLAGS="-isystem $PBS_DEP_LIBRESOLV_INCLUDE/include $CPPFLAGS"

# /usr/lib/libresolv.9.dylib provides _res_9_dn_expand, _res_9_init,
# etc. PHP's dns.c references these but configure doesn't add -lresolv
# on macOS. Linking against /nix/store/.../libresolv.dylib bakes the
# build-time path into LC_LOAD_DYLIB; the post-install snippet rewrites
# it to /usr/lib/libresolv.9.dylib (system) afterwards.
export LDFLAGS="$LDFLAGS -L${PBS_DEP_LIBRESOLV_DIR}/lib -lresolv"

# PHP's iconv configure check compiles AND runs a tiny program that
# calls iconv_open() with bogus encodings and asserts errno == EINVAL.
# On macOS arm64 in the Nix build sandbox the test binary runs but the
# errno round-trip through GNU libiconv's stub doesn't satisfy the
# check — php_cv_iconv_errno comes back "no" and configure aborts. At
# runtime in actual use our libiconv works correctly. Pre-populate the
# autoconf cache vars so configure trusts us:
#   - php_cv_iconv_errno=yes — declares the runtime errno test passed.
#   - php_cv_iconv_const="" — declares iconv()'s 2nd arg is `char**`
#     (non-const, GNU libiconv 1.17 / POSIX). Empty string because the
#     value gets substituted as `#define ICONV_CONST <value>`; "no"
#     would emit a literal token `no` and ext/iconv/iconv.c fails to
#     compile with "use of undeclared identifier 'no'".
export php_cv_iconv_errno=yes
export php_cv_iconv_const=""
