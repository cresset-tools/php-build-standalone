# NSPR (Netscape Portable Runtime) bundled-dep derivation.
#
# NSS pulls this in; PBS doesn't link anything else against it directly.
# The tarball extracts to a doubly-nested layout (`nspr-<v>/nspr/`) with
# `configure` at the inner level, so override `srcSubdir` accordingly.
#
# `--enable-64bit` is required on x86_64 and aarch64; without it NSPR's
# configure picks 32-bit codegen which then fails to link against the
# 64-bit toolchain. NSPR predates auto-detection of host word size.
{ mkDep, pkgs }:
mkDep {
  name = "nspr";
  builder = "autotools";
  srcSubdir = v: "nspr-${v}/nspr";
  configureFlags = [
    "--enable-64bit"
  ];
  # NSPR's `make install` deposits a `nspr-config` script and headers
  # under `include/nspr/`. NSS's configure expects that layout, so we
  # don't strip anything from there. We DO trim the `.a` static
  # archives that NSPR's build always emits regardless of
  # `--disable-static` — they're useless dead weight in the
  # downstream tarball.
  postInstallCleanup = [
    "lib/libnspr4.a"
    "lib/libplc4.a"
    "lib/libplds4.a"
  ];
  auditLibs = [ "libnspr4" "libplc4" "libplds4" ];
}
