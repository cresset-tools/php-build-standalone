# libxslt bundled-dep derivation. Depends on libxml2 (XPath / parser
# foundation) and zlib (libxml2 transitively, but pulled in here so the
# build script can stamp a -L flag at libxslt's link line if needed).
{ mkDep, libxml2, zlib }:
mkDep {
  name = "libxslt";
  deps = [ libxml2 zlib ];
}
