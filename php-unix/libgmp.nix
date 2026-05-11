# libgmp — GNU Multiple Precision arithmetic library. Built via mkDep's
# autotools template; libgmp configure has no flags we need to override.
# PHP's ext/gmp consumes it for arbitrary-precision integer/rational/float
# math (JWT RSA/EC libraries, password hashers that compute modular
# exponents in userland, blockchain code).
#
# auditLibs: "libgmp". libgmpxx (the C++ wrapper) is also built by default;
# we don't ship it explicitly. mkDep's audit ignores library names not in
# this list, so libgmpxx just rides along in $out/lib if produced.
{ mkDep }:
mkDep {
  name = "libgmp";
  builder = "autotools";
  # Upstream tarball is `gmp-<v>.tar.xz` and extracts to `gmp-<v>/`, not
  # `libgmp-<v>/` like our internal key.
  srcSubdir = v: "gmp-${v}";
  # --disable-cxx skips libgmpxx (the C++ wrapper). PHP's ext/gmp uses only
  # the C API, and libgmpxx pulls a libstdc++ dependency we'd otherwise
  # need to static-link in. --enable-fat builds a runtime CPU-feature
  # dispatch table so a single libgmp.so works across the manylinux
  # consumer matrix without re-tuning for the build machine's exact CPU.
  configureFlags = [ "--disable-cxx" "--enable-fat" ];
  auditLibs = [ "libgmp" ];
}
