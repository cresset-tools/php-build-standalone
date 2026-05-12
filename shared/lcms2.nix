# lcms2 bundled-dep derivation. Little CMS color-management library;
# ImageMagick uses it for ICC-profile-aware color conversion
# (--with-lcms). Self-contained — no external deps.
{ mkDep }:
mkDep {
  name = "lcms2";
  builder = "autotools";
  postInstallCleanup = [ "bin" "share" ];
  auditLibs = [ "liblcms2" ];
}
