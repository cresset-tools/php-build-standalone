# libssh2 bundled-dep derivation. Client-side SSH2 protocol library;
# consumed by the `ssh2` PECL extension (ssh2_connect, ssh2_exec, the
# ssh2.sftp:// / ssh2.scp:// stream wrappers).
#
# Crypto backend is pinned to the bundled openssl rather than left on
# configure's `auto` probe: libssl is the one C-lib this distribution
# never duplicates (see CLAUDE.md §libssl pinning), and `auto` would
# happily settle on a host libgcrypt / mbedtls if it found one first.
# zlib backs the optional `zlib@openssh.com` transport compression.
#
# Autotools template applies: the release tarball ships a pre-generated
# `configure`.
{ mkDep, openssl, zlib }:
mkDep {
  name = "libssh2";
  builder = "autotools";
  deps = [ openssl zlib ];
  configureFlags = [
    "--with-crypto=openssl"
    ''--with-libssl-prefix="$PBS_DEP_OPENSSL"''
    "--with-libz"
    ''--with-libz-prefix="$PBS_DEP_ZLIB"''
    # The example programs link the just-built lib and bake the build
    # dir into their RPATHs; the test suite wants Docker/sshd. Nothing
    # downstream needs either.
    "--disable-examples-build"
    "--disable-docker-tests"
    "--disable-sshd-tests"
  ];
  auditLibs = [ "libssh2" ];
}
