# libxcrypt — modern crypt(3) implementation. Replaces the libcrypt that
# was bundled with glibc through 2.38 and dropped in 2.39+. Builds clean
# with the standard autotools template; the upstream tarball includes
# configure and accepts a plain --prefix override.
#
# We build with --enable-hashes=strong (drops obsolete DES/NTHASH) plus
# the default obsolete-API set so MariaDB's crypt()/crypt_r() calls
# resolve. --disable-failure-tokens keeps libxcrypt from returning
# unusable strings on hash-method-unsupported, matching MariaDB's
# expectations from the glibc-bundled libcrypt era.
{ mkDep }:
mkDep {
  name = "libxcrypt";
  builder = "autotools";
  configureFlags = [
    "--disable-static"
    "--enable-shared"
    "--enable-hashes=strong,glibc"
    # --enable-obsolete-api=glibc ships BOTH the glibc-compat libcrypt.so.1
    # ABI and libxcrypt's own libcrypt.so.2. This matches the distro
    # defaults (Debian, Fedora, Arch) and means any consumer linked against
    # either ABI version of libcrypt loads cleanly. --enable-obsolete-api=no
    # would have shipped libcrypt.so.2 only, breaking anything (MariaDB
    # included) that was originally linked against the glibc-bundled
    # libcrypt.so.1.
    "--enable-obsolete-api=glibc"
    # libxcrypt's util-xbzero.c uses an inline-asm trick with a VLA-typed
    # pointer cast that clang flags as -Wlanguage-extension-token. Default
    # configure turns warnings into errors, killing the build. Upstream
    # gates this behind --enable-werror; disabling matches what most
    # distros do (and PBS prioritizes "builds clean against a clang
    # toolchain" over libxcrypt's strict-warnings CI policy).
    "--disable-werror"
  ];
  auditLibs = [ "libcrypt" ];
}
