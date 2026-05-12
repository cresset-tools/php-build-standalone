# libxml2 bundled-dep derivation. Depends on zlib for compressed-xml
# support (PHP's xml ext expects this codepath to exist).
{ mkDep, zlib }:
mkDep {
  name = "libxml2";
  deps = [ zlib ];
}
