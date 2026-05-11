# Darwin-only libiconv bundled-dep derivation. Linux uses glibc's iconv
# directly; macOS's apple-sdk strips legacy libiconv headers, so we bundle
# GNU libiconv. The libiconv build is part of the Darwin closure only —
# the Linux release derivation does not pull this in.
{ mkDep }:
mkDep {
  name = "libiconv";
  builder = "autotools";
  postInstallCleanup = [ "bin" "share" ];
  auditLibs = [ "libiconv" ];
}
